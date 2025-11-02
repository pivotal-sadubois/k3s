#!/bin/bash

export NAMESPACE=dvwa1
export APPNAME=dvwa
export APPDESC="DVWA Demo"
export DOCKER_IMAGE=k8s.gcr.io/echoserver:1.10
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

if [ "$1" == "delete" -o "$1" == "delete" ]; then 
  echo "=> Undeploy '$APPDESC' Deployment ($APPNAME)"
  kubectl -n $NAMESPACE delete ingress ${APPNAME}-corelab
  kubectl -n $NAMESPACE delete ingress ${APPNAME}-fortidemo
  kubectl -n $NAMESPACE delete service ${APPNAME}-web-service
  kubectl -n $NAMESPACE delete service ${APPNAME}-mysql-service
  kubectl -n $NAMESPACE delete deployment ${APPNAME}-web
  kubectl -n $NAMESPACE delete deployment ${APPNAME}-mysql
  kubectl -n $NAMESPACE delete secret ${APPNAME}-secrets
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


###
### Deployment Metadata
###
metadata:
  name: dvwa-web
###
### Specs
###
spec:
  replicas: 1

  selector:
    matchLabels:
      app: dvwa-web
      tier: frontend

  template:

    # Template Metadata to be used by service for discovery
    metadata:
      labels:
        app: dvwa-web
        tier: frontend

    # Container/Volume definition
    spec:
      containers:
        - name: dvwa
          image: cytopia/dvwa:php-8.1
          ports:
            - containerPort: 80
          env:
            - name: RECAPTCHA_PRIV_KEY
              valueFrom:
                configMapKeyRef:
                  name: dvwa-config
                  key: RECAPTCHA_PRIV_KEY
            - name: RECAPTCHA_PUB_KEY
              valueFrom:
                configMapKeyRef:
                  name: dvwa-config
                  key: RECAPTCHA_PUB_KEY
            - name: SECURITY_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: dvwa-config
                  key: SECURITY_LEVEL
            - name: PHPIDS_ENABLED
              valueFrom:
                configMapKeyRef:
                  name: dvwa-config
                  key: PHPIDS_ENABLED
            - name: PHPIDS_VERBOSE
              valueFrom:
                configMapKeyRef:
                  name: dvwa-config
                  key: PHPIDS_VERBOSE
            - name: PHP_DISPLAY_ERRORS
              valueFrom:
                configMapKeyRef:
                  name: dvwa-config
                  key: PHP_DISPLAY_ERRORS

            - name: MYSQL_HOSTNAME
              value: dvwa-mysql-service
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: dvwa-secrets
                  key: DVWA_DATABASE
            - name: MYSQL_USERNAME
              valueFrom:
                secretKeyRef:
                  name: dvwa-secrets
                  key: DVWA_USERNAME
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: dvwa-secrets
                  key: DVWA_PASSWORD

EOF

echo " ▪ Create Deployment MySQL"
cat <<EOF | kubectl -n $NAMESPACE  apply -f -
apiVersion: apps/v1
kind: Deployment


###
### Deployment Metadata
###
metadata:
  name: dvwa-mysql


###
### Specs
###
spec:
  replicas: 1

  selector:
    matchLabels:
      app: dvwa-mysql
      tier: backend

  template:

    # Template Metadata to be used by service for discovery
    metadata:
      labels:
        app: dvwa-mysql
        tier: backend

    # Container/Volume definition
    spec:
      containers:
        - name: mysql
          image: mariadb:10.1
          ports:
            - containerPort: 3306
          volumeMounts:
            - name: dvwa-mysql-vol
              mountPath: /var/lib/mysql
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: dvwa-secrets
                  key: ROOT_PASSWORD
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: dvwa-secrets
                  key: DVWA_USERNAME
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: dvwa-secrets
                  key: DVWA_PASSWORD
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: dvwa-secrets
                  key: DVWA_DATABASE
      volumes:
        - name: dvwa-mysql-vol
          hostPath:
            path: "/var/lib/mysql"
EOF

echo " ▪ Create ConfigMap"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: dvwa-config
data:
  RECAPTCHA_PRIV_KEY: ""
  RECAPTCHA_PUB_KEY: ""
  SECURITY_LEVEL: "low"
  PHPIDS_ENABLED: "0"
  PHPIDS_VERBOSE: "1"
  PHP_DISPLAY_ERRORS: "1"
EOF

echo " ▪ Create Database Secret"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${APPNAME}-secrets
type: Opaque
data:
  ROOT_PASSWORD: czNyMDB0cGE1NQ==
  DVWA_USERNAME: ZHZ3YQ==
  DVWA_PASSWORD: cEBzc3dvcmQ=
  DVWA_DATABASE: ZHZ3YQ==
EOF

echo " ▪ Create DVWA Web Services"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APPNAME}-web-service
spec:
  selector:
    app: dvwa-web
    tier: frontend
  type: ClusterIP
  ports:
    - protocol: TCP
      # Port accessible inside cluster
      port: $EXPOSE_PORT
      # Port to forward to inside the pod
      targetPort: $CONTAINER_PORT
EOF

echo " ▪ Create DVWA MySQL Service"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APPNAME}-mysql-service
spec:
  selector:
    app: dvwa-mysql
    tier: backend
  ports:
    - protocol: TCP
      port: 3306
      targetPort: 3306
EOF

# ----------

echo " ▪ Expose Container Port: $CONTAINER_PORT to $EXPOSE_PORT service Type: $SERVICE_TYPE"
cat <<EOF | kubectl -n $NAMESPACE apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $APPNAME
spec:
  selector:
    app: dvwa-web-service
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
            name: ${APPNAME}-web-service
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
            name: ${APPNAME}-web-service
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





