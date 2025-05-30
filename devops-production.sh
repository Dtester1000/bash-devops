#!/usr/bin/env bash

# Features: Error handling, idempotency, configuration management, and best practices

set -o errexit          # Exit on any error
set -o nounset          # Exit on undefined variables
set -o pipefail         # Fail pipelines if any command fails
shopt -s globstar nullglob # Enable advanced globbing

# Configuration - Environment Variables
readonly PROJECT_URL="https://github.com/Dtester1000/chat-clone.git"
readonly PROJECT_NAME="chat-clone"
readonly DOCKER_REGISTRY="docker.io"
readonly INGRESS_CONTROLLER_VERSION="controller-v1.8.1"
readonly MONGODB_IMAGE="mongo:latest"
readonly NAMESPACE="chat-app"
readonly TIMEOUT=180     # Seconds to wait for deployments

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color
readonly BLUE='\033[0;34m'

# Logging functions
log_info() {
  printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
  printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2
}

log_error() {
  printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
  exit 1
}

log_debug() {
  printf "${BLUE}[DEBUG]${NC} %s\n" "$1"
}

# Check prerequisites
check_prerequisites() {
  local tools=("git" "docker" "kubectl" "curl" "jq")
  local missing=()
  
  for tool in "${tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
  fi

  # Check Docker is running
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running"
  fi

  # Check Kubernetes cluster is available
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "Kubernetes cluster is not available"
  fi
}

# Cleanup function
cleanup() {
  log_info "Cleaning up previous deployment..."
  
  # Delete Kubernetes resources if they exist
  kubectl delete ingress chat-ingress --namespace="$NAMESPACE" --ignore-not-found=true
  kubectl delete -f k8s/ --ignore-not-found=true
  
  # Remove Docker images
  docker rmi -f "$DOCKER_REGISTRY/chat-server:latest" "$DOCKER_REGISTRY/chat-public:latest" 2>/dev/null || true
  
  # Remove project directory
  if [[ -d "$PROJECT_NAME" ]]; then
    rm -rf "$PROJECT_NAME"
  fi

   # Kill SonarQube port-forward if running
  if [[ -n "$SONARQUBE_PF_PID" ]]; then
    kill "$SONARQUBE_PF_PID" 2>/dev/null || true
  fi
}



# Setup namespace
setup_namespace() {
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_info "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
  else
    log_info "Namespace $NAMESPACE already exists"
  fi
}

# Clone and prepare repository
prepare_repository() {
  log_info "Cloning repository..."
  git clone --depth 1 "$PROJECT_URL" || log_error "Failed to clone repository"
  
  cd "$PROJECT_NAME" || log_error "Failed to enter project directory"
  
  # Remove unnecessary files (if they exist)
  [[ -d "images" ]] && rm -rf images
  [[ -f "README.md" ]] && rm -f README.md
}

# Build and push Docker images
build_and_push_images() {
  local services=("server" "public")
  
  for service in "${services[@]}"; do
    local image_name="chat-$service"
    local image_tag="$DOCKER_REGISTRY/$image_name:latest"
    
    log_info "Building Docker image for $image_name..."
    docker build -t "$image_tag" "./$service" || log_error "Failed to build $image_name image"
    
    log_info "Pushing $image_name to registry..."
    docker push "$image_tag" || log_error "Failed to push $image_name image"
  done
}

# Install SonarQube in Kubernetes
install_sonarqube() {
  log_info "Setting up SonarQube for code quality analysis..."
  
  # Create namespace if it doesn't exist
  if ! kubectl get namespace "$SONARQUBE_NAMESPACE" >/dev/null 2>&1; then
    kubectl create namespace "$SONARQUBE_NAMESPACE"
  fi

  # Add SonarQube Helm repo if not already added
  if ! helm repo list | grep -q sonarqube; then
    helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
    helm repo update
  fi

  # Install SonarQube
  helm upgrade --install -n "$SONARQUBE_NAMESPACE" sonarqube sonarqube/sonarqube \
    --set service.type=ClusterIP \
    --set persistence.enabled=true \
    --set persistence.size=5Gi \
    --set postgresql.persistence.size=5Gi \
    --wait

  # Wait for SonarQube to be ready
  log_info "Waiting for SonarQube to be ready..."
  kubectl wait --namespace "$SONARQUBE_NAMESPACE" \
    --for=condition=ready pod \
    --selector=app=sonarqube \
    --timeout=${TIMEOUT}s

  # Port-forward to access SonarQube (background process)
  kubectl port-forward -n "$SONARQUBE_NAMESPACE" svc/sonarqube-sonarqube 9000:9000 &
  SONARQUBE_PF_PID=$!
  sleep 5

  # Change default admin password
  log_info "Updating SonarQube admin password..."
  curl -u "$SONARQUBE_USER:admin" -X POST "http://localhost:9000/api/users/change_password" \
    --data-urlencode "login=$SONARQUBE_USER" \
    --data-urlencode "password=$SONARQUBE_PASSWORD" \
    --data-urlencode "previousPassword=admin" || log_warn "Password change may have failed"
}

# Run SonarQube analysis
run_sonarqube_analysis() {
  log_info "Running SonarQube code analysis..."
  
  # Check if we're in the project directory
  if [[ ! -d "$PROJECT_NAME" ]]; then
    log_error "Project directory not found. Run prepare_repository first."
  fi

  cd "$PROJECT_NAME" || log_error "Failed to enter project directory"

  # Check for sonar-project.properties, create if doesn't exist
  if [[ ! -f "sonar-project.properties" ]]; then
    log_info "Creating sonar-project.properties file..."
    cat > sonar-project.properties <<EOF
sonar.projectKey=chat-clone
sonar.projectName=Chat Clone Application
sonar.projectVersion=1.0
sonar.sources=.
sonar.sourceEncoding=UTF-8
sonar.host.url=http://localhost:9000
sonar.login=$SONARQUBE_USER
sonar.password=$SONARQUBE_PASSWORD
sonar.exclusions=**/node_modules/**,**/dist/**,**/coverage/**,**/test/**,**/tests/**
EOF
  fi

  # Run SonarScanner (assuming it's installed)
  if command -v sonar-scanner >/dev/null 2>&1; then
    sonar-scanner \
      -Dsonar.projectKey=chat-clone \
      -Dsonar.sources=. \
      -Dsonar.host.url=http://localhost:9000 \
      -Dsonar.login="$SONARQUBE_USER" \
      -Dsonar.password="$SONARQUBE_PASSWORD" || log_warn "SonarQube analysis encountered issues"
  else
    log_warn "sonar-scanner not found. Skipping code analysis."
    return 0
  fi

  # Wait for analysis to complete and get quality gate status
  local project_status
  project_status=$(curl -s -u "$SONARQUBE_USER:$SONARQUBE_PASSWORD" \
    "http://localhost:9000/api/qualitygates/project_status?projectKey=chat-clone" | \
    jq -r '.projectStatus.status')

  if [[ "$project_status" == "OK" ]]; then
    log_info "SonarQube Quality Gate PASSED"
  else
    log_error "SonarQube Quality Gate FAILED. Status: $project_status"
  fi
}

# Run tests
run_tests() {
  log_info "Running application tests..."
  
  cd "$PROJECT_NAME" || log_error "Failed to enter project directory"

  # Check for test scripts and run them
  if [[ -f "package.json" ]]; then
    log_info "Running npm tests..."
    npm install && npm test || log_error "Tests failed"
  elif [[ -f "pom.xml" ]]; then
    log_info "Running maven tests..."
    mvn test || log_error "Tests failed"
  elif [[ -f "build.gradle" ]]; then
    log_info "Running gradle tests..."
    ./gradlew test || log_error "Tests failed"
  else
    log_warn "No recognized test configuration found. Skipping tests."
  fi
}

# Setup MongoDB
setup_mongodb() {
  log_info "Setting up MongoDB..."
  
  # Create a ConfigMap for MongoDB initialization
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-init
data:
  init.js: |
    db.createUser({
      user: "chatUser",
      pwd: "chatPassword",
      roles: [ { role: "readWrite", db: "chatdb" } ]
    });
EOF

  # Deployment with persistence and authentication
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
spec:
  serviceName: mongodb
  replicas: 1
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
        image: $MONGODB_IMAGE
        ports:
        - containerPort: 27017
        env:
        - name: MONGO_INITDB_DATABASE
          value: chatdb
        - name: MONGO_INITDB_ROOT_USERNAME
          value: root
        - name: MONGO_INITDB_ROOT_PASSWORD
          value: rootPassword
        volumeMounts:
        - name: mongodb-data
          mountPath: /data/db
        - name: mongodb-init
          mountPath: /docker-entrypoint-initdb.d/init.js
          subPath: init.js
      volumes:
      - name: mongodb-init
        configMap:
          name: mongodb-init
  volumeClaimTemplates:
  - metadata:
      name: mongodb-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 1Gi
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
}

# Deploy application services
deploy_services() {
  log_info "Deploying application services..."
  
  # Create a ConfigMap for environment configuration
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: chat-config
data:
  MONGODB_URI: "mongodb://chatUser:chatPassword@mongodb-service:27017/chatdb?authSource=chatdb"
EOF

  # Deploy chat-server
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chat-server
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: chat-server
    spec:
      containers:
      - name: chat-server
        image: $DOCKER_REGISTRY/chat-server:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3000
        envFrom:
        - configMapRef:
            name: chat-config
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 15
          periodSeconds: 20
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

  # Deploy chat-public
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-public
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chat-public
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: chat-public
    spec:
      containers:
      - name: chat-public
        image: $DOCKER_REGISTRY/chat-public:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        readinessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 15
          periodSeconds: 20
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
}

# Setup ingress
setup_ingress() {
  log_info "Setting up Ingress Controller..."
  
  # Install NGINX Ingress Controller if not already installed
  if ! kubectl get pods -n ingress-nginx 2>/dev/null | grep -q ingress-nginx-controller; then
    kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_CONTROLLER_VERSION/deploy/static/provider/cloud/deploy.yaml"
    
    log_info "Waiting for Ingress Controller to be ready..."
    kubectl wait --namespace ingress-nginx \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=${TIMEOUT}s
  else
    log_info "Ingress Controller already installed"
  fi

  log_info "Configuring Ingress..."
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chat-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/proxy-body-size: "10m" # Limits the buffer to 10MB.
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60s" # Timeout for slow clients
    nginx.ingress.kubernetes.io/enable-cors: "true" # Enables cors for cross origin requests
    nginx.ingress.kubernetes.io/cors-allow-methods: "PUT, GET, POST, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-origin: "*"
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
}

# Verify deployment
verify_deployment() {
  log_info "Verifying deployment..."
  
  local retries=10
  local delay=10
  
  for ((i=1; i<=retries; i++)); do
    if kubectl get pods -n "$NAMESPACE" | grep -v "Running" | grep -q "chat"; then
      log_warn "Some pods are not yet running. Retrying in $delay seconds... ($i/$retries)"
      sleep "$delay"
    else
      log_info "All pods are running!"
      return 0
    fi
  done
  
  log_error "Deployment verification timed out. Some pods are not running."
}

# --- Menu Functions ---
show_main_menu() {
  clear
  echo -e "${GREEN}Kubernetes Deployment Manager${NC}"
  log_info "You can access the application at http://localhost"
  log_info "API is available at http://localhost/api"
  log_info "SonarQube dashboard: http://localhost:9000 (admin/$SONARQUBE_PASSWORD)"
  echo -e "${BLUE}============================${NC}"
  echo "1. Install"
  echo "2. Run Tests"
  echo "3. Cleanup Resources"
  echo "4. Exit"
  echo -e "${BLUE}============================${NC}"
}

press_any_key() {
  read -n 1 -s -r -p "Press any key to continue..."
  echo
}

process_menu_choice() {
  local choice
  read -p "Enter your choice [1-4]: " choice
  case $choice in
    1) 
      check_prerequisites
      setup_namespace
      prepare_repository
      install_sonarqube
      run_tests
      run_sonarqube_analysis
      build_and_push_images
      setup_mongodb
      deploy_services
      setup_ingress
      verify_deployment
      press_any_key
      ;;
    2) 
      run_tests
      run_sonarqube_analysis
      press_any_key
      ;;
    3)
      cleanup
      press_any_key
      ;;
    4) 
      log_info "Exiting..."
      exit 0
      ;;
    *) 
      log_error "Invalid option"
      press_any_key
      ;;
  esac
}

# --- Main Execution ---
main() {
  # Check basic prerequisites at startup
  if ! command -v kubectl &> /dev/null || ! command -v docker &> /dev/null; then
    log_warn "Some tools are missing. Run 'Install Prerequisites' first."
  fi
  
  
  # Interactive menu loop
  while true; do
    show_main_menu
    process_menu_choice
  done
}

# Start the script
main "$@"
