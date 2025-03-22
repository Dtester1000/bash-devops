#!/bin/bash

set -e

# Repository URL
REPO_URL="https://github.com/Dtester1000/chat-clone.git"
REPO_DIR="chat-clone"

# Function to check if an image exists and pull it if it doesn't
check_and_pull_image() {
    if ! docker image inspect "$1" &> /dev/null; then
        echo "Pulling $1 image..."
        docker pull "$1" || { echo "Failed to pull $1 image"; exit 1; }
    else
        echo "$1 image already exists."
    fi
}

# Check and pull required images
check_and_pull_image "mongo:latest"
check_and_pull_image "sonarqube:latest"

# Clone the repository without authentication
if [ ! -d "$REPO_DIR" ]; then
    echo "Cloning repository..."
    sudo git clone "$REPO_URL" || { echo "Failed to clone repository."; exit 1; }
    sleep 60
else
    echo "Repository already exists. Skipping clone."
fi

# Navigate to the repository
cd "$REPO_DIR" || { echo "Failed to navigate to repository directory."; exit 1; }

# Install backend dependencies
echo "Installing backend dependencies..."
cd server || { echo "Failed to navigate to backend directory."; exit 1; }
npm install || { echo "Failed to install backend dependencies. Make sure you have Node.js and npm installed."; exit 1; }
cd ..

# Install frontend dependencies
echo "Installing frontend dependencies..."
cd public || { echo "Failed to navigate to frontend directory."; exit 1; }
npm install || { echo "Failed to install frontend dependencies. Make sure you have Node.js and npm installed."; exit 1; }
cd ..

# Start Minikube
echo "Starting Minikube..."
minikube start || { echo "Failed to start Minikube. Please ensure it's correctly installed."; exit 1; }

# Enable ingress addon
echo "Enabling Ingress addon..."
minikube addons enable ingress

# Set docker env to use Minikube's Docker daemon
eval $(minikube docker-env)

# Build backend image
echo "Building backend image..."
cd backend || { echo "Failed to navigate to backend directory."; exit 1; }
docker build -t chat-backend:latest . || { echo "Failed to build backend image. Check your Dockerfile in backend directory."; exit 1; }
cd ..

# Build frontend image
echo "Building frontend image..."
cd frontend || { echo "Failed to navigate to frontend directory."; exit 1; }
docker build -t chat-frontend:latest . || { echo "Failed to build frontend image. Check your Dockerfile in frontend directory."; exit 1; }
cd ..

# Apply Kubernetes manifests
echo "Applying Kubernetes manifests..."

# MongoDB
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
  name: mongodb
spec:
  selector:
    app: mongodb
  ports:
    - protocol: TCP
      port: 27017
      targetPort: 27017
EOF

# Backend
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-backend
spec:
  selector:
    matchLabels:
      app: chat-backend
  template:
    metadata:
      labels:
        app: chat-backend
    spec:
      containers:
      - name: chat-backend
        image: chat-backend:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: chat-backend
spec:
  selector:
    app: chat-backend
  ports:
    - protocol: TCP
      port: 5000
      targetPort: 5000
EOF

# Frontend
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-frontend
spec:
  selector:
    matchLabels:
      app: chat-frontend
  template:
    metadata:
      labels:
        app: chat-frontend
    spec:
      containers:
      - name: chat-frontend
        image: chat-frontend:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 3000
---
apiVersion: v1
kind: Service
metadata:
  name: chat-frontend
spec:
  selector:
    app: chat-frontend
  ports:
    - protocol: TCP
      port: 3000
      targetPort: 3000
EOF

# SonarQube
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarqube
spec:
  selector:
    matchLabels:
      app: sonarqube
  template:
    metadata:
      labels:
        app: sonarqube
    spec:
      containers:
      - name: sonarqube
        image: sonarqube:latest
        ports:
        - containerPort: 9000
---
apiVersion: v1
kind: Service
metadata:
  name: sonarqube
spec:
  selector:
    app: sonarqube
  ports:
    - protocol: TCP
      port: 9000
      targetPort: 9000
EOF

# Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod -l app=mongodb --timeout=120s
kubectl wait --for=condition=Ready pod -l app=chat-backend --timeout=120s
kubectl wait --for=condition=Ready pod -l app=chat-frontend --timeout=120s
kubectl wait --for=condition=Ready pod -l app=sonarqube --timeout=120s

# Get frontend URL
FRONTEND_URL=$(minikube service chat-frontend --url)
echo "Frontend URL: $FRONTEND_URL"

# Test frontend
echo "Testing frontend availability..."
STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL")

if [ "$STATUS_CODE" -eq "200" ]; then
  echo "Frontend is accessible! HTTP Status: $STATUS_CODE"
else
  echo "Frontend is not accessible. HTTP Status: $STATUS_CODE"
fi

# Get backend URL
BACKEND_URL=$(minikube service chat-backend --url)
echo "Backend URL: $BACKEND_URL"

# Test backend
echo "Testing backend availability..."
STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_URL/api/health")

if [ "$STATUS_CODE" -eq "200" ]; then
  echo "Backend is accessible! HTTP Status: $STATUS_CODE"
else
  echo "Backend is not accessible. HTTP Status: $STATUS_CODE"
fi

echo "Setup complete. Please check the individual services for any specific errors."
