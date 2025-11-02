#!/bin/bash

export NAMESPACE=edb-static
export APPNAME=edb
export DOCKER_IMAGE=sadubois/employeedb:1.3.0

[ -f $HOME/.tanzu-demo-hub.cfg ] && . $HOME/.tanzu-demo-hub.cfg
[ -f $HOME/workspace/tanzu-demo-hub/functions ] && . $HOME/workspace/tanzu-demo-hub/functions

echo "Install EmployeeDB Demo with ingress and TLS"

echo " ▪ Create / update namespace $NAMESPACE"
kubectl create ns $NAMESPACE > /dev/null 2>&1

echo " ▪ Create a docker pull secret"
dockerPullSecret $NAMESPACE > /dev/null 2>&1

echo " ▪ Create a datasource secret for the MySQL backend"
kubectl create secret generic mysql-credentials \
        --from-literal=spring.datasource.username=bitnami \
        --from-literal=spring.datasource.password=bitnami \
        --namespace $NAMESPACE > /dev/null 2>&1

echo "# Deploy $APPNAME"
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
        - containerPort: 8080
        env:
          - name: SPRING_PROFILES_ACTIVE
            value: "production"
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
        resources:
          limits:
            memory: "4Gi"
            cpu: "1"
          requests:
            memory: "1Gi"
            cpu: "300m"
EOF

echo "# Expose NGINX via ClusterIP Service"
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
      port: 8080
      targetPort: 8080
  type: LoadBalancer
EOF

sleep 10

ip=$(kubectl -n $NAMESPACE get svc $APPNAME -o json | jq -r '.status.loadBalancer.ingress[].ip')

echo "curl http://$ip"


