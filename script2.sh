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
# Assuming you have Dockerfiles in server/ and public/ directories
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
        imagePullPolicy: IfNotPresent # Added imagePullPolicy
        ports:
        - containerPort: 3000 # Or whichever port your server uses
        env:
        - name: MONGODB_URI
          value: "mongodb://mongodb-service:27017/chatdb" # Ensure this matches your server's expected env var
---
apiVersion: v1
kind: Service
metadata:
  name: chat-server-service
spec:
  type: LoadBalancer # Use NodePort if LoadBalancer is not supported
  selector:
    app: chat-server
  ports:
    - protocol: TCP
      port: 3000 # Expose server port
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
        imagePullPolicy: IfNotPresent # Added imagePullPolicy
        ports:
        - containerPort: 80 # Or whichever port your public app uses
---
apiVersion: v1
kind: Service
metadata:
  name: chat-public-service
spec:
  type: LoadBalancer # Use NodePort if LoadBalancer is not supported
  selector:
    app: chat-public
  ports:
    - protocol: TCP
      port: 80 # Expose public app port
      targetPort: 80
EOF


echo "Application deployed to Kubernetes. Check the services to access them."
