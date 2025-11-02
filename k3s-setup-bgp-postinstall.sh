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

# install calicoctl"
curl -L https://github.com/projectcalico/calico/releases/download/v3.30.0/calicoctl-linux-amd64 -o calicoctl
chmod +x calicoctl
sudo mv calicoctl /usr/local/bin/

cat <<'YAML' | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 64513
  # optional but nice to be explicit
  logSeverityScreen: Info
YAML

kubectl patch ippool default-ipv4-ippool --type merge -p '{"spec":{"ipipMode":"Never","vxlanMode":"Never"}}'

cat <<'YAML' | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: fgt-lan
spec:
  peerIP: 10.0.20.1         # FortiGate IP on the LAN
  asNumber: 64512           # FortiGate ASN
  # Optional: restrict which nodes peer (here: all)
  # nodeSelector: all()
YAML

# Verify Status
sudo -E calicoctl node status

# get pod ip address
kubectl get pods -A -o wide | awk 'NR==1 || /Running/{print $1,$2,$7}'


