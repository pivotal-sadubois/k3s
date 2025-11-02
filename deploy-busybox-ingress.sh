#!/bin/bash

export NAMESPACE=busybox
export APPNAME=busybox
export APPDESC="Busybox HTTP Demo"
export DOCKER_IMAGE=busybox:latest
export CONTAINER_PORT=8080
export EXPOSE_PORT=80
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

if [ "$1" == "delete" ]; then 
  echo "=> Undeploy '$APPDESC' Deployment ($APPNAME)"
  kubectl -n $NAMESPACE delete ingress ${APPNAME}-corelab
  kubectl -n $NAMESPACE delete ingress ${APPNAME}-fortidemo
  kubectl -n $NAMESPACE delete svc $APPNAME
  kubectl -n $NAMESPACE delete deployment $APPNAME
  kubectl -n $NAMESPACE delete secret fortidemo-tls-cert 
  kubectl -n $NAMESPACE delete secret core-tls-secret
  kubectl delete ns $NAMESPACE
  echo "$APPDESC undeployed successfully"
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
        command: ["/bin/sh", "-c"]
        args:
          - httpd -f -p 8080 && sleep infinity
        ports:
        - containerPort: $CONTAINER_PORT
        resources:
          limits:
            memory: "256Mi"
            cpu: "500m"
          requests:
            memory: "64Mi"
            cpu: "100m"
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

# TLS Secret management
nam=$(kubectl get secrets -n $NAMESPACE -o json | jq -r --arg key "$TLS_FORTIDEMO_SECRET" '.items[].metadata | select(.name == $key).name')
if [ "$nam" == "" ]; then 
  echo " ▪ Create TLS Certificate secret ($TLS_FORTIDEMO_SECRET) Expiring: $TLS_FORTIDEMO_EXPRIRE"
  kubectl create secret tls $TLS_FORTIDEMO_SECRET \
    --namespace $NAMESPACE \
    --cert=$TLS_FORTIDEMO_CERTPATH/${TLS_FORTIDEMO_CERTNAME}.cer \
    --key=$TLS_FORTIDEMO_CERTPATH/${TLS_FORTIDEMO_CERTNAME}.key
fi

nam=$(kubectl get secrets -n $NAMESPACE -o json | jq -r --arg key "$TLS_CORELAB_SECRET" '.items[].metadata | select(.name == $key).name')
if [ "$nam" == "" ]; then 
  echo " ▪ Create TLS Certificate secret ($TLS_CORELAB_SECRET) Expiring: $TLS_CORELAB_EXPRIRE"
  kubectl create secret tls $TLS_CORELAB_SECRET \
    --namespace $NAMESPACE \
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
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - secretName: $TLS_FORTIDEMO_SECRET
    hosts:
    - "*.$DNS_DOMAIN_FORTIDEMO"
  rules:
  - host: ${APPNAME}.$DNS_DOMAIN_FORTIDEMO
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

echo " ▪ Create Ingress Resource for $APPNAME for Domain: $DNS_DOMAIN_CORELAB"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APPNAME}-corelab
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - secretName: $TLS_CORELAB_SECRET
    hosts:
    - "*.$DNS_DOMAIN_CORELAB"
  rules:
  - host: ${APPNAME}.$DNS_DOMAIN_CORELAB
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
kubectl -n $NAMESPACE get all,ingress
echo "----------------------------------------------------------------------------------------------------------------"
echo "kubectl -n $NAMESPACE get all,ingress"
echo 

echo " ▪ Test Application for Domain: $DNS_DOMAIN_FORTIDEMO"
echo "   curl https://$APPNAME.$DNS_DOMAIN_FORTIDEMO --cacert certificates/fortidemoCA.crt"
echo ""
echo " ▪ Test Application for Domain: $DNS_DOMAIN_CORELAB"
echo "   curl https://$APPNAME.$DNS_DOMAIN_CORELAB"
echo ""
echo " ▪ To login into the the pod"
echo "   kubectl -n busybox exec -it $(kubectl -n busybox get pod -l app=busybox -o jsonpath='{.items[0].metadata.name}') -- /bin/sh"
echo ""
