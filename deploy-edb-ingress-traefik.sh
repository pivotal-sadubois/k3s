#!/bin/bash
#===============================================================================
# SCRIPT NAME:    deploy-edb-ingress-traefik.sh
# DESCRIPTION:    Deploy Fortinet EmployeeDB Application (SAML, LDAPS health)
# AUTHOR:         Sacha Dubois, Fortinet (+ ChatGPT tweaks)
# CREATED:        2025-03-30
# VERSION:        1.2
#===============================================================================
# CHANGE LOG:
# 2025-03-30 sdubois Initial version
# 2025-07-06 sdubois Added FortiADC Ingress
# 2025-10-15 chatgpt  Add PKIX truststore, SAML fixes
# 2025-10-16 chatgpt  Add LDAP bind secret + LDAPS health
#===============================================================================

# -------------------- Tunables --------------------
[ "${ADC_INGRESS:-}" == "" ] && ADC_INGRESS=1
NAMESPACE=edb-ingress-traefik
APPNAME=edb
APPDESC="EmployeeDB Demo"
DOCKER_IMAGE=sadubois/employeedb:1.5.2
CONTAINER_PORT=8080
EXPOSE_PORT=80
SERVICE_TYPE=ClusterIP

# FortiDemo CA 
TLS_FORTIDEMO_CA_CERT=FortidemoCA.crt
TLS_FORTIDEMO_CERTPATH=$HOME/Documents/Certificate/PrivateCA/fortidemoCA

# Ingress (Traefik)
TLS_INGRESS_APPINT_CERTNAME=AppsIntFortiDemoCH
TLS_INGRESS_APPINT_SECRET=fortidemo-appint-tls-cert
TLS_INGRESS_APPINT_EXPRIRE=$(openssl x509 -in "$TLS_FORTIDEMO_CERTPATH/${TLS_INGRESS_APPINT_CERTNAME}.crt" -noout -dates | tail -1 | sed 's/^.*=//g')
TLS_INGRESS_APPINT_DOMAIN=apps-int.fortidemo.ch
TLS_INGRESS_APPINT_IPADDR=$(dig +short "$APPNAME.$TLS_INGRESS_APPINT_DOMAIN")

# DB-Access credentials
DB_SERVER=10.0.20.13
DB_PORT=3306
DB_USER=bitnami
DB_PASSWORD=bitnami

# -------------------- SAML (IdP) --------------------
IDP_PREFIX=edbint
IDP_METADATA_URI="https://fortiauth.fortidemo.ch/saml-idp/${IDP_PREFIX}/metadata"
IDP_LOGOUT_URL="https://fortiauth.fortidemo.ch/saml-idp/${IDP_PREFIX}/logout/"

RELYING_ENTITY_ID="${APPNAME}.${TLS_INGRESS_APPINT_DOMAIN}"
SERVER_BASE_URL="https://${APPNAME}.${TLS_INGRESS_APPINT_DOMAIN}"

# Secret containing the IdP CA (already used by truststore init)
IDP_CA_SECRET_NAME=idp-ca
IDP_CA_KEY_NAME=$TLS_FORTIDEMO_CA_CERT  # ca.crt on disk -> key name in secret

# -------------------- LDAP/LDAPS Health --------------------
LDAP_BIND_SECRET=ldap-credentials
LDAP_BIND_DN_KEY=bind_dn
LDAP_BIND_PW_KEY=bind_password
LDAP_PASSWORD='im2fast4u$'
LDAP_BIND_DN='uid=brian,ou=Users,dc=fortidemo,dc=ch'

# LDAPS endpoint
LDAP_URL="ldaps://fortiauth.fortidemo.ch:636"
LDAP_BASE="dc=fortidemo,dc=ch"

# -----------------------------------------------------------
[ -f "$HOME/.tanzu-demo-hub.cfg" ] && . "$HOME/.tanzu-demo-hub.cfg"
[ -f "$HOME/workspace/tanzu-demo-hub/functions" ] && . "$HOME/workspace/tanzu-demo-hub/functions"

if [ "${1:-}" == "delete" ]; then
  echo "=> Undeploy '$APPDESC' Deployment ($APPNAME)"
  kubectl -n "$NAMESPACE" delete ingress "${APPNAME}-fortidemo" --ignore-not-found
  kubectl -n "$NAMESPACE" delete svc "$APPNAME" --ignore-not-found
  kubectl -n "$NAMESPACE" delete deployment "$APPNAME" --ignore-not-found
  kubectl -n "$NAMESPACE" delete secret "$TLS_INGRESS_APPINT_SECRET" --ignore-not-found
  kubectl -n "$NAMESPACE" delete secret "$IDP_CA_SECRET_NAME" --ignore-not-found
  kubectl -n "$NAMESPACE" delete secret "$LDAP_BIND_SECRET" --ignore-not-found
  kubectl delete ns "$NAMESPACE" --ignore-not-found
  echo "$APPDESC undeployed successfully"
  exit 0
fi

echo "=> Deploy '$APPDESC' Deployment ($APPNAME)"
echo " ▪ Create / update namespace $NAMESPACE"
kubectl create ns "$NAMESPACE" >/dev/null 2>&1 || true

echo " ▪ Create a docker pull secret"
dockerPullSecret "$NAMESPACE" >/dev/null 2>&1 || true
echo gaga1

echo " ▪ Create datasource secret for the MySQL backend (if missing)"
if ! kubectl get secret -n "$NAMESPACE" mysql-credentials >/dev/null 2>&1; then
  kubectl create secret generic mysql-credentials \
    --from-literal=spring.datasource.username="$DB_USER" \
    --from-literal=spring.datasource.password="$DB_PASSWORD" \
    --namespace "$NAMESPACE" >/dev/null
fi
echo gaga2

echo " ▪ Ensure IdP CA secret ($IDP_CA_SECRET_NAME) exists"
kubectl -n "$NAMESPACE" create secret generic "$IDP_CA_SECRET_NAME" \
  --from-file="$IDP_CA_KEY_NAME=$TLS_FORTIDEMO_CERTPATH/$TLS_FORTIDEMO_CA_CERT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo " ▪ Ensure LDAP bind secret ($LDAP_BIND_SECRET) exists"
kubectl -n "$NAMESPACE" create secret generic "$LDAP_BIND_SECRET" \
  --from-literal="$LDAP_BIND_DN_KEY=$LDAP_BIND_DN" \
  --from-literal="$LDAP_BIND_PW_KEY=$LDAP_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo " ▪ Create / Update Deployment"
cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
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
      # -------------------- Init: build PKCS12 truststore with IdP CA --------------------
      initContainers:
        - name: build-truststore
          image: eclipse-temurin:21-jre
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              ls -l /certs
              keytool -importcert -trustcacerts -noprompt \
                -alias idp-ca \
                -keystore /work/truststore.p12 \
                -storetype PKCS12 \
                -storepass changeit \
                -file /certs/$IDP_CA_KEY_NAME
              keytool -list -keystore /work/truststore.p12 -storepass changeit | grep -i idp-ca
          volumeMounts:
            - { name: truststore, mountPath: /work }
            - { name: idp-ca, mountPath: /certs, readOnly: true }

      containers:
        - name: $APPNAME
          image: $DOCKER_IMAGE
          ports:
            - containerPort: $CONTAINER_PORT
          env:
            # --- DB ---
            - name: SPRING_DATASOURCE_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: spring.datasource.username
            - name: SPRING_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: spring.datasource.password
            - name: SPRING_DATASOURCE_URL
              value: jdbc:mysql://$DB_SERVER:$DB_PORT/employeedb?createDatabaseIfNotExist=true

            # --- Profile ---
            - name: SPRING_PROFILES_ACTIVE
              value: "fabric-studio"

            # --- SAML mode ---
            - name: EDB_AUTHENTICATION
              value: "saml"
            - name: SERVER_BASE_URL
              value: "$SERVER_BASE_URL"
            - name: EDB_SAML_ENTITY_ID
              value: "$RELYING_ENTITY_ID"
            - name: EDB_SAML_IDP_METADATA_URI
              value: "$IDP_METADATA_URI"
            - name: EDB_SAML_IDP_LOGOUT_URL
              value: "$IDP_LOGOUT_URL"
            - name: EDB_SAML_POST_LOGOUT_REDIRECT
              value: "/"

            # Spring Security relaxed-binding equivalents
            - name: SPRING_SECURITY_SAML2_RELYINGPARTY_REGISTRATION_FORTIAUTH_ASSERTINGPARTY_METADATA_URI
              value: "$IDP_METADATA_URI"
            - name: SPRING_SECURITY_SAML2_RELYINGPARTY_REGISTRATION_FORTIAUTH_ENTITY_ID
              value: "$RELYING_ENTITY_ID"
            - name: SPRING_SECURITY_SAML2_RELYINGPARTY_REGISTRATION_FORTIAUTH_ASSERTION_CONSUMER_SERVICE_LOCATION
              value: "$SERVER_BASE_URL/login/saml2/sso/fortiauth"

            # --- LDAPS for health check (and any LDAP usage) ---
            - name: SPRING_LDAP_URLS
              value: "$LDAP_URL"
            - name: SPRING_LDAP_BASE
              value: "$LDAP_BASE"
            - name: SPRING_LDAP_USERNAME
              valueFrom:
                secretKeyRef:
                  name: $LDAP_BIND_SECRET
                  key: $LDAP_BIND_DN_KEY
            - name: SPRING_LDAP_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $LDAP_BIND_SECRET
                  key: $LDAP_BIND_PW_KEY

            # --- Logging (optional) ---
            - name: LOGGING_LEVEL_ORG_SPRINGFRAMEWORK_SECURITY_SAML2
              value: "DEBUG"
            - name: LOGGING_LEVEL_ORG_SPRINGSECURITY
              value: "DEBUG"
            - name: LOGGING_LEVEL_ORG_SPRINGFRAMEWORK_SECURITY
              value: "DEBUG"

            # --- Java truststore path to include our IdP CA (also used by LDAPS) ---
            - name: JAVA_TOOL_OPTIONS
              value: "-Djavax.net.ssl.trustStore=/app/trust/truststore.p12 -Djavax.net.ssl.trustStorePassword=changeit"

          volumeMounts:
            - { name: truststore, mountPath: /app/trust }

          resources:
            limits:
              memory: "4Gi"
              cpu: "1"
            requests:
              memory: "1Gi"
              cpu: "300m"

      volumes:
        - name: truststore
          emptyDir: {}
        - name: idp-ca
          secret:
            secretName: $IDP_CA_SECRET_NAME
EOF

echo " ▪ Expose Container Port: $CONTAINER_PORT to $EXPOSE_PORT service Type: $SERVICE_TYPE"
cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
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

echo " ▪ Create TLS Certificate secret ($TLS_INGRESS_APPINT_SECRET) Expiring: $TLS_INGRESS_APPINT_EXPRIRE"
if ! kubectl get secret -n "$NAMESPACE" "$TLS_INGRESS_APPINT_SECRET" >/dev/null 2>&1; then
  kubectl create secret tls "$TLS_INGRESS_APPINT_SECRET" \
    --namespace "$NAMESPACE" \
    --cert="$TLS_FORTIDEMO_CERTPATH/${TLS_INGRESS_APPINT_CERTNAME}.crt" \
    --key="$TLS_FORTIDEMO_CERTPATH/${TLS_INGRESS_APPINT_CERTNAME}.key"
fi

echo " ▪ Create Ingress Resource (Traefik) for Domain: $TLS_INGRESS_APPINT_DOMAIN"
cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
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
    - secretName: $TLS_INGRESS_APPINT_SECRET
      hosts:
        - "*.$TLS_INGRESS_APPINT_DOMAIN"
  rules:
    - host: ${APPNAME}.$TLS_INGRESS_APPINT_DOMAIN
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

kubectl -n "$NAMESPACE" delete deploy/header-echo svc/header-echo --ignore-not-found
kubectl -n "$NAMESPACE" delete middleware.traefik.io/add-proxy-headers --ignore-not-found

echo " ▪ Deploy header-echo (shows raw incoming HTTP headers) and wire it at /debug/headers"
# Pod/Service (idempotent)
kubectl -n "$NAMESPACE" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: header-echo
  labels: { app: header-echo }
spec:
  replicas: 1
  selector: { matchLabels: { app: header-echo } }
  template:
    metadata: { labels: { app: header-echo } }
    spec:
      containers:
        - name: echo
          image: ghcr.io/mendhak/http-https-echo:30
          ports: [{containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata:
  name: header-echo
spec:
  selector: { app: header-echo }
  ports:
    - name: http
      port: 80
      targetPort: 8080
YAML

# Optional: Traefik middleware to inject an easy-to-spot header (Traefik already adds X-Forwarded-* automatically)
kubectl -n "$NAMESPACE" apply -f - <<'YAML'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: add-proxy-headers
spec:
  headers:
    customRequestHeaders:
      X-Notification: "Header Injected Successful"
YAML

# Attach /debug/headers path to the existing Ingress and apply middleware
kubectl -n "$NAMESPACE" patch ingress "${APPNAME}-fortidemo" --type='json' -p="[
  {\"op\":\"add\",\"path\":\"/metadata/annotations/traefik.ingress.kubernetes.io~1router.middlewares\",\"value\":\"$NAMESPACE-add-proxy-headers@kubernetescrd\"},
  {\"op\":\"add\",\"path\":\"/spec/rules/0/http/paths/-\",\"value\":{
      \"path\":\"/debug/headers\",
      \"pathType\":\"Prefix\",
      \"backend\":{\"service\":{\"name\":\"header-echo\",\"port\":{\"number\":80}}}
  }}
]" || true

kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l app="$APPNAME" --timeout=300s || true

echo " ▪ Show Deployment"
echo "----------------------------------------------------------------------------------------------------------------"
kubectl -n "$NAMESPACE" get all,ingress
echo "----------------------------------------------------------------------------------------------------------------"
echo "kubectl -n $NAMESPACE get all,ingress"
echo
echo " ▪ Test Application for Domains:"
echo "   => curl -I https://$APPNAME.$TLS_INGRESS_APPINT_DOMAIN/employees/list --cacert $TLS_FORTIDEMO_CERTPATH/$TLS_FORTIDEMO_CA_CERT"
echo " ▪ Test header echo:"
echo "   curl -s https://${APPNAME}.${TLS_INGRESS_APPINT_DOMAIN}/debug/headers --cacert $TLS_FORTIDEMO_CERTPATH/$TLS_FORTIDEMO_CA_CERT | jq"

echo
