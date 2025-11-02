
#!/bin/bash 
#===============================================================================
# SCRIPT NAME:    deploy-breathtestshiny-ingress.sh
# DESCRIPTION:    Deploy the breathtestshiny app in namespace breathtestshiny
# AUTHOR:         Sacha Dubois, Fortinet
# CREATED:        2025-04-15
# VERSION:        1.0
#===============================================================================
# CHANGE LOG:
# 2025-04-15 sdubois Initial version
#===============================================================================

export NAMESPACE=breathtestshiny
export APPNAME=breathtestshiny
export APPDESC="WebSocket Demo"
export DOCKER_IMAGE=dmenne/breathtestshiny
export CONTAINER_PORT=3838
export EXPOSE_PORT=3838
export SERVICE_TYPE=ClusterIP
export TLS_FORTIDEMO_CERTPATH=./certificates
export TLS_FORTIDEMO_CERTNAME=apps-tkg-fortidemo
export TLS_FORTIDEMO_SECRET=fortidemo-tls-cert
export TLS_FORTIDEMO_EXPRIRE=$(openssl x509 -in $TLS_FORTIDEMO_CERTPATH/${TLS_FORTIDEMO_CERTNAME}.cer -noout -dates | tail -1 | sed 's/^.*=//g')
export DNS_DOMAIN_FORTIDEMO=apps.tkg.fortidemo.ch

export DNS_DOMAIN_CORELAB=apps.tkg.corelab.core-software.ch
export TLS_CORELAB_CERTPATH=$HOME/Documents/Certificate/STAR.apps.tkg.corelab.core-software.ch
export TLS_CORELAB_CERTNAME=k8s-apps-core
export TLS_CORELAB_SECRET=core-tls-secret
export TLS_CORELAB_EXPRIRE=$(openssl x509 -in $TLS_CORELAB_CERTPATH/${TLS_CORELAB_CERTNAME}.crt -noout -dates | tail -1 | sed 's/^.*=//g')

[ -f $HOME/.tanzu-demo-hub.cfg ] && . $HOME/.tanzu-demo-hub.cfg
[ -f $HOME/workspace/tanzu-demo-hub/functions ] && . $HOME/workspace/tanzu-demo-hub/functions

if [ "$1" == "delete" -o "$1" == "delete" ]; then 
  echo "=> Undeploy '$APPDESC' Deployment ($APPNAME)"
  kubectl -n $NAMESPACE delete ingress ${APPNAME}-corelab
  kubectl -n $NAMESPACE delete ingress ${APPNAME}-fortidemo
  kubectl -n $NAMESPACE delete svc $APPNAME
  kubectl -n $NAMESPACE delete deployment $APPNAME
  kubectl -n $NAMESPACE delete secret fortidemo-tls-cert 
  kubectl -n $NAMESPACE delete secret core-tls-secret
  kubectl delete ns $NAMESPACE
  echo "$APPDESC undeployed successfuully"

  exit
fi

echo "=> Deploy '$APPDESC' Deployment ($APPNAME)"
echo " ▪ Create / update namespace $NAMESPACE"
kubectl create ns $NAMESPACE > /dev/null 2>&1

echo " ▪ Create a docker pull secret"
dockerPullSecret $NAMESPACE > /dev/null 2>&1

echo " ▪ Create Deployment"
cat <<EOF | kubectl -n $NAMESPACE  apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APPNAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APPNAME
  template:
    metadata:
      labels:
        app: $APPNAME
    spec:
      containers:
      - name: $APPNAME
        image: $DOCKER_IMAGE
        ports:
        - containerPort: $CONTAINER_PORT
        resources:
          limits:
            memory: "4Gi"
            cpu: "1"
          requests:
            memory: "1Gi"
            cpu: "300m"
EOF

echo " ▪ Expose Container Port: $CONTAINER_PORT to $EXPOSE_PORT service Type: $SERVICE_TYPE"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $APPNAME
spec:
  selector:
    app: $APPNAME
  ports:
    - protocol: TCP
      port: $EXPOSE_PORT
      targetPort: $CONTAINER_PORT
  type: $SERVICE_TYPE
EOF

if [ "$nam" == "" ]; then 
  echo " ▪ Create TLS Certificate secret ($TLS_FORTIDEMO_SECRET) Expiring: $TLS_FORTIDEMO_EXPRIRE"
  nam=$(kubectl get secrets -n $NAMESPACE -o json | jq -r --arg key "$TLS_CORELAB_SECRET" '.items[].metadata | select(.name == $key).name' )
  kubectl create secret tls $TLS_FORTIDEMO_SECRET \
    --namespace $NAMESPACE \
    --cert=$TLS_FORTIDEMO_CERTPATH/${TLS_FORTIDEMO_CERTNAME}.cer \
    --key=$TLS_FORTIDEMO_CERTPATH/${TLS_FORTIDEMO_CERTNAME}.key
fi

nam=$(kubectl get secrets -n $NAMESPACE -o json | jq -r --arg key "$TLS_CORELAB_SECRET" '.items[].metadata | select(.name == $key).name' )
if [ "$nam" == "" ]; then 
  echo " ▪ Create TLS Certificate secret ($TLS_CORELAB_SECRET) Expiring: $TLS_CORELAB_EXPRIRE"
  export CERTPATH=$HOME/Documents/Certificate/STAR.apps.tkg.corelab.core-software.ch
  kubectl -n $NAMESPACE create secret tls $TLS_CORELAB_SECRET \
    --cert=$TLS_CORELAB_CERTPATH/${TLS_CORELAB_CERTNAME}.crt \
    --key=$TLS_CORELAB_CERTPATH/${TLS_CORELAB_CERTNAME}.key
fi

echo " ▪ Create Ingress Resource for $APPNAME for Domain: $DNS_DOMAIN_FORTIDEMO"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APPNAME}-fortidemo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure      # Use only HTTPS entrypoint
    traefik.ingress.kubernetes.io/router.tls: "true"                 # Enable TLS
spec:
  ingressClassName: traefik
  tls:
  - secretName: $TLS_FORTIDEMO_CERTNAME   # Secret containing the TLS certificate
    hosts:
    - "*.$DNS_DOMAIN_FORTIDEMO"     # Wildcard domain covered by the certificate
  rules:
  - host: ${APPNAME}.$DNS_DOMAIN_FORTIDEMO   # Your specific hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $APPNAME
            port:
              number: $EXPOSE_PORT
EOF

echo " ▪ Create Ingress Resource for $APPNAME for domain: $DNS_DOMAIN_CORELAB"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APPNAME}-corelab
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure      # Use only HTTPS entrypoint
    traefik.ingress.kubernetes.io/router.tls: "true"                 # Enable TLS
spec:
  ingressClassName: traefik
  tls:
  - secretName: $TLS_CORELAB_SECRET   # Secret containing the TLS certificate
    hosts:
    - "*.$DNS_DOMAIN_CORELAB"     # Wildcard domain covered by the certificate
  rules:
  - host: ${APPNAME}.$DNS_DOMAIN_CORELAB   # Your specific hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $APPNAME
            port:
              number: $EXPOSE_PORT
EOF



echo " ▪ Show Deployment"
echo "----------------------------------------------------------------------------------------------------------------"
kubectl -n $NAMESPACE get all,ingress,Middleware
echo "----------------------------------------------------------------------------------------------------------------"
echo "kubectl -n $NAMESPACE get all,ingress,Middleware"
echo 

echo " ▪ Test Application for Domain: $DNS_DOMAIN_FORTIDEMO"
echo "   curl https://$APPNAME.$DNS_DOMAIN_FORTIDEMO --cacert certificates/fortidemoCA.crt"
echo ""
echo " ▪ Test Application for Domain: $DNS_DOMAIN_CORELAB"
echo "   curl https://$APPNAME.$DNS_DOMAIN_CORELAB"
echo ""





