#!/bin/bash

# Script to deploy chat-clone to a local Kubernetes cluster using Docker Desktop

# Project URL
PROJECT_URL="https://github.com/Dtester1000/chat-clone.git"
PROJECT_NAME="chat-clone"

# Function to handle errors
error_exit() {
  echo "Error: $1" >&2
  exit 1
}

# 1. Pull the repository
echo "Pulling the repository..."
git clone "$PROJECT_URL" || error_exit "Failed to clone the repository."
cd "$PROJECT_NAME" || error_exit "Failed to change directory to project folder."

# 2. Clean up unnecessary files
echo "Cleaning up unnecessary files..."
rm -rf images || error_exit "Failed to remove images folder."
rm -f README.md || error_exit "Failed to remove README.md file."

# 3. Build Docker images
echo "Building Docker images..."
docker build -t chat-server ./server || error_exit "Failed to build chat-server image."
docker build -t chat-public ./public || error_exit "Failed to build chat-public image."

# Tag the images for Kubernetes (using docker.io)
docker tag chat-server docker.io/chat-server:latest
docker tag chat-public docker.io/chat-public:latest

# Push the images to docker.io
docker push docker.io/chat-server:latest
docker push docker.io/chat-public:latest

# 4. Create MongoDB container
echo "Creating MongoDB container..."
docker pull mongo:latest || error_exit "Failed to pull mongo image."

# 5. Deploy to Kubernetes
echo "Deploying to Kubernetes..."

# Deploy NGINX Ingress Controller (if not already present)
echo "Setting up NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml

# Wait for the Ingress Controller to be ready
echo "Waiting for NGINX Ingress Controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

# Define Kubernetes Deployment and Service for MongoDB
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb
spec:
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
      - name: mongodb
        image: mongo:latest
        ports:
        - containerPort: 27017
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb-service
spec:
  selector:
    app: mongodb
  ports:
    - protocol: TCP
      port: 27017
      targetPort: 27017
EOF

# Define Kubernetes Deployment and Service for chat-server
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-server
spec:
  selector:
    matchLabels:
      app: chat-server
  template:
    metadata:
      labels:
        app: chat-server
    spec:
      containers:
      - name: chat-server
        image: docker.io/chat-server:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3000
        env:
        - name: MONGODB_URI
          value: "mongodb://mongodb-service:27017/chatdb"
---
apiVersion: v1
kind: Service
metadata:
  name: chat-server-service
spec:
  type: ClusterIP  
  selector:
    app: chat-server
  ports:
    - protocol: TCP
      port: 3000
      targetPort: 3000
EOF

# Define Kubernetes Deployment and Service for chat-public
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-public
spec:
  selector:
    matchLabels:
      app: chat-public
  template:
    metadata:
      labels:
        app: chat-public
    spec:
      containers:
      - name: chat-public
        image: docker.io/chat-public:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: chat-public-service
spec:
  type: ClusterIP
  selector:
    app: chat-public
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF

echo "Configuring Ingress..."

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chat-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: chat-public-service
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: chat-server-service
            port:
              number: 3000
EOF

sleep 15
echo "Application deployed to Kubernetes. Check the services to access them."
