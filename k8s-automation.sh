#!/bin/bash

set -e

# Global variables
KEDA_NAMESPACE="keda"
HELM_CHART_KEDA="kedacore/keda"
DEPLOYMENT_NAMESPACE="default"
KEDA_TRIGGER_TYPE="cpu"

# Utility: Log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Validate prerequisites
check_prerequisites() {
    for cmd in kubectl helm; do
        if ! command -v $cmd &> /dev/null; then
            echo "Error: $cmd is not installed." >&2
            exit 1
        fi
    done
}

# Select Kubernetes context
select_kube_context() {
    log "Fetching available contexts..."
    contexts=$(kubectl config get-contexts -o name)
    if [ -z "$contexts" ]; then
        echo "No Kubernetes contexts found. Exiting."
        exit 1
    fi
    echo "$contexts"
    read -p "Enter context name to use: " selected_context
    kubectl config use-context "$selected_context"
    log "Using context: $selected_context"
}

# Install Helm if not already present
install_helm_if_needed() {
    if ! helm version &>/dev/null; then
        echo "Helm not found. Please install Helm before running this script."
        exit 1
    fi
}

# Install KEDA using Helm
install_keda() {
    log "Installing KEDA..."
    helm repo add kedacore https://kedacore.github.io/charts
    helm repo update
    helm upgrade --install keda $HELM_CHART_KEDA \
        --namespace $KEDA_NAMESPACE \
        --create-namespace

    log "Waiting for KEDA to be ready..."
    kubectl rollout status deployment/keda-operator -n $KEDA_NAMESPACE --timeout=120s
    log "KEDA installed successfully."
}

# Create deployment with autoscaling
create_deployment() {
    DEPLOYMENT_NAME=$1
    IMAGE_NAME=$2
    CPU_REQUEST=$3
    CPU_LIMIT=$4
    RAM_REQUEST=$5
    RAM_LIMIT=$6
    PORT=$7

    log "Creating deployment $DEPLOYMENT_NAME with image $IMAGE_NAME..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT_NAME
  namespace: $DEPLOYMENT_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOYMENT_NAME
  template:
    metadata:
      labels:
        app: $DEPLOYMENT_NAME
    spec:
      containers:
      - name: app-container
        image: $IMAGE_NAME
        ports:
        - containerPort: $PORT
        resources:
          requests:
            cpu: "$CPU_REQUEST"
            memory: "$RAM_REQUEST"
          limits:
            cpu: "$CPU_LIMIT"
            memory: "$RAM_LIMIT"
EOF

    log "Deployment $DEPLOYMENT_NAME created."
}

# Create a KEDA ScaledObject (CPU-based example, can be extended)
create_scaled_object() {
    DEPLOYMENT_NAME=$1
    MIN_REPLICAS=$2
    MAX_REPLICAS=$3
    TARGET_AVG_CPU=$4

    log "Creating KEDA ScaledObject for $DEPLOYMENT_NAME..."
    cat <<EOF | kubectl apply -f -
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${DEPLOYMENT_NAME}-scaledobject
  namespace: $DEPLOYMENT_NAMESPACE
spec:
  scaleTargetRef:
    name: $DEPLOYMENT_NAME
  minReplicaCount: $MIN_REPLICAS
  maxReplicaCount: $MAX_REPLICAS
  triggers:
  - type: cpu
    metadata:
      type: Utilization
      value: "$TARGET_AVG_CPU"
EOF
    log "ScaledObject created."
}

# Get deployment status
get_deployment_status() {
    DEPLOYMENT_NAME=$1
    log "Fetching status for deployment $DEPLOYMENT_NAME..."
    kubectl get deployment "$DEPLOYMENT_NAME" -n $DEPLOYMENT_NAMESPACE -o wide
    log "Pods:"
    kubectl get pods -l app="$DEPLOYMENT_NAME" -n $DEPLOYMENT_NAMESPACE -o wide
    log "ScaledObject Status:"
    kubectl get scaledobject ${DEPLOYMENT_NAME}-scaledobject -n $DEPLOYMENT_NAMESPACE -o yaml | grep -A10 'status:' || echo "Status not yet available."
}

# Help function
usage() {
    echo "Usage: $0 [command]"
    echo "Commands:"
    echo "  setup                     - Setup cluster tools (Helm, KEDA)"
    echo "  deploy <name> <image> <cpu_req> <cpu_lim> <mem_req> <mem_lim> <port>"
    echo "  scale <name> <min> <max> <target_cpu>"
    echo "  status <name>            - Get status of a deployment"
    echo "  context                  - List and select kube context"
    exit 1
}

# Main
main() {
    check_prerequisites

    case "$1" in
        setup)
            install_helm_if_needed
            install_keda
            ;;
        deploy)
            if [ $# -ne 8 ]; then
                usage
            fi
            create_deployment "$2" "$3" "$4" "$5" "$6" "$7" "$8"
            ;;
        scale)
            if [ $# -ne 5 ]; then
                usage
            fi
            create_scaled_object "$2" "$3" "$4" "$5"
            ;;
        status)
            if [ $# -ne 2 ]; then
                usage
            fi
            get_deployment_status "$2"
            ;;
        context)
            select_kube_context
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
