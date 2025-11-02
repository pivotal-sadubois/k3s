#!/usr/bin/bash
#===============================================================================
# SCRIPT NAME:    $HOME/workspace/k3s/k3s-setup_calico_nosnat.sh
# DESCRIPTION:    Install K3s With OSS Calico (no SNAT) + MetalLB
# AUTHOR:         Sacha Dubois, Fortinet
# CREATED:        2025-03-14
# VERSION:        1.2 (cleaned: no Flannel/ServiceLB conflicts)
#===============================================================================
# K3s + Calico OSS (no SNAT, no encapsulation) + MetalLB (L2) + Traefik (LB)
# Clean, conflict-free: Flannel disabled, K3s ServiceLB disabled.
# Pods CIDR: 192.168.0.0/16
# MetalLB Pool: 10.0.20.150-10.0.20.179
#===============================================================================
set -euo pipefail

# ================= Tunables (adjust if needed) =================
K3S_VERSION="v1.33.5+k3s1"
NODE_IP="10.0.20.197"
TLS_SANS=("10.0.20.101" "10.0.20.197")
POD_CIDR="192.168.0.0/16"            # Calico pod network
CALICO_VERSION="v3.30.0"
METALLB_RANGE="10.0.20.150-10.0.20.179"
WAIT_TIMEOUT="420s"
# ===============================================================

need_root(){ [[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)."; exit 1; }; }
say(){ echo -e "\n==> $*"; }
join_yaml_array(){ local IFS=$'\n'; printf -- "- %s\n" "$@"; }

need_root

# 0) Helm (best effort)
say "Installing Helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1 || true

# 1) Authoritative K3s config + audit policy
say "Writing audit policy + /etc/rancher/k3s/config.yaml"
mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
EOF

cat >/etc/rancher/k3s/config.yaml <<EOF
write-kubeconfig-mode: "0644"
tls-san:
$(join_yaml_array "${TLS_SANS[@]}")
cluster-cidr: "${POD_CIDR}"
flannel-backend: "none"   # disable flannel dataplane
disable:
  - traefik
  - servicelb
kube-apiserver-arg:
  - audit-policy-file=/etc/rancher/k3s/audit-policy.yaml
  - audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log
  - audit-log-maxage=30
  - audit-log-maxbackup=10
  - audit-log-maxsize=100
EOF

# 2) Stop K3s (if any) & scrub CNI/flannel leftovers
say "Stopping K3s (if running) and scrubbing CNI/flannel"
systemctl stop k3s 2>/dev/null || true
rm -f /etc/cni/net.d/* 2>/dev/null || true
rm -f /var/lib/rancher/k3s/agent/etc/cni/net.d/* 2>/dev/null || true
rm -rf /var/lib/cni/* 2>/dev/null || true
rm -f /var/lib/rancher/k3s/agent/flannel/* 2>/dev/null || true
for iface in flannel.1 cni0 tunl0; do
  ip link show "$iface" &>/dev/null && { ip link set "$iface" down || true; ip link del "$iface" || true; }
done

# 3) Install/start K3s (reads config.yaml)
say "Installing K3s ${K3S_VERSION} (config-file driven)"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -

# 4) Point kubeconfig to NODE_IP and wait API
say "Pointing kubeconfig to ${NODE_IP} and waiting for API"
mkdir -p /root/.kube
sed "s/127.0.0.1/${NODE_IP}/g" /etc/rancher/k3s/k3s.yaml > /root/.kube/config
export KUBECONFIG=/root/.kube/config
for i in {1..60}; do kubectl get ns &>/dev/null && break || sleep 2; done
kubectl get ns >/dev/null

# 5) Install Calico and ensure IPPool exists (no-encap, no-SNAT)
say "Applying Calico ${CALICO_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

say "Waiting for CRDs (ippools.crd.projectcalico.org)"
for i in {1..90}; do
  kubectl get crd ippools.crd.projectcalico.org &>/dev/null && break || sleep 2
done
kubectl get crd ippools.crd.projectcalico.org >/dev/null

# Create the pool explicitly (don’t assume it exists)
say "Creating/Upserting IPPool default-ipv4-ippool (no IPIP/VXLAN, no SNAT)"
cat <<EOF | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: ${POD_CIDR}
  blockSize: 26
  ipipMode: Never
  vxlanMode: Never
  natOutgoing: false
  nodeSelector: all()
  allowedUses:
    - Workload
EOF

# Wait for calico-node to exist, then be Ready
say "Ensuring a calico-node pod exists"
for i in {1..90}; do
  kubectl -n kube-system get pods -l k8s-app=calico-node -o name 2>/dev/null | grep -q 'pod/' && break || sleep 2
done
kubectl -n kube-system get pods -l k8s-app=calico-node

say "Waiting for calico-node Ready"
if ! kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout="${WAIT_TIMEOUT}"; then
  echo "calico-node not Ready — dumping describe/logs for hints:"
  kubectl -n kube-system get pods -l k8s-app=calico-node -o wide || true
  kubectl -n kube-system describe ds/calico-node || true
  kubectl -n kube-system logs -l k8s-app=calico-node --tail=200 --all-containers=true || true
  exit 1
fi
kubectl -n kube-system wait --for=condition=Available deploy/calico-kube-controllers --timeout="${WAIT_TIMEOUT}" || true

kubectl get ippool default-ipv4-ippool -o yaml | egrep 'cidr|ipipMode|vxlanMode|natOutgoing'

# 6) Install MetalLB (native) + pool + advert
say "Installing MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.10/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=ready pod -l app=metallb --timeout=300s

say "Configuring MetalLB pool ${METALLB_RANGE} + L2Advertisement"
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - lan-pool
EOF

# 7) Install Traefik as LoadBalancer
say "Installing Traefik (LoadBalancer via MetalLB)"
helm repo add traefik https://traefik.github.io/charts >/dev/null || true
helm repo update >/dev/null || true
helm upgrade --install traefik traefik/traefik -n kube-system --set service.type=LoadBalancer

say "Waiting for Traefik EXTERNAL-IP"
for i in {1..90}; do
  EP="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${EP}" ]] && break || sleep 2
done
kubectl -n kube-system get svc traefik -o wide
echo "EXTERNAL-IP: ${EP:-<pending>}"

# 8) Final sanity
say "Verifying pods use ${POD_CIDR} and no K3s ServiceLB leftovers"
kubectl get pods -A -o wide | awk 'NR==1 || /Running/{printf "%-18s %-45s %-15s\n",$1,$2,$7}'
kubectl -n kube-system get pods | grep -q '^svclb-' && echo "WARNING: svclb pods found (ServiceLB should be disabled)" || echo "ServiceLB disabled ✓"

# 2) Make sure your kubeconfig points to the node IP (not 127.0.0.1)
sed -i 's/127\.0\.0\.1/10.0.20.197/g' /etc/rancher/k3s/k3s.yaml
chmod a+r /etc/rancher/k3s/k3s.yaml 

echo "Installation Completed !!
echo "To create a local kubeconfig, execute the following command on K3s host"
echo "=> cp /etc/rancher/k3s/k3s.yaml ~/.kube/config"
echo "   chown \"$(id -u):$(id -g)\" ~/.kube/config"
echo ""
echo "Create a local kubeconfig on you MacBook do the following: "
sudo "=> scp sdubois@10.0.20.197:/home/sdubois/.kube/config $HOME/.kube/config"


