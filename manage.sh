#!/bin/bash

# Valkey REST API Docker Management Script
# This script manages the Docker container for the Valkey REST API

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
CONTAINER_NAME="valkey-rest-api"
IMAGE_NAME="valkey-rest"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to parse YAML config file
# Simple YAML parser - handles basic key: value pairs
parse_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Config file not found: $CONFIG_FILE"
        print_info "Please copy config.yaml.example to config.yaml and update it"
        exit 1
    fi

    # Use Python if available for better YAML parsing
    if command_exists python3; then
        python3 <<EOF
import yaml
import sys
import os

try:
    with open('$CONFIG_FILE', 'r') as f:
        config = yaml.safe_load(f)
    
    api_port = config.get('api', {}).get('port', '8080')
    api_token = config.get('api', {}).get('auth_token', '')
    valkey_addr = config.get('valkey', {}).get('address', 'localhost:6379')
    valkey_pass = config.get('valkey', {}).get('password', '')
    network_mode = config.get('docker', {}).get('network_mode', 'host')
    
    print(f"PORT={api_port}")
    print(f"AUTH_TOKEN={api_token}")
    print(f"VALKEY_ADDRESS={valkey_addr}")
    print(f"VALKEY_PASSWORD={valkey_pass}")
    print(f"NETWORK_MODE={network_mode}")
except Exception as e:
    print(f"Error parsing config: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    elif command_exists yq; then
        # Use yq if available
        echo "PORT=$(yq eval '.api.port // "8080"' "$CONFIG_FILE")"
        echo "AUTH_TOKEN=$(yq eval '.api.auth_token // ""' "$CONFIG_FILE")"
        echo "VALKEY_ADDRESS=$(yq eval '.valkey.address // "localhost:6379"' "$CONFIG_FILE")"
        echo "VALKEY_PASSWORD=$(yq eval '.valkey.password // ""' "$CONFIG_FILE")"
        echo "NETWORK_MODE=$(yq eval '.docker.network_mode // "host"' "$CONFIG_FILE")"
    else
        # Simple grep-based parser as fallback
        print_warn "Python3 or yq not found. Using simple parser (may be less reliable)"
        grep -E "^[[:space:]]*(port|auth_token|address|password|network_mode):" "$CONFIG_FILE" | \
        sed 's/^[[:space:]]*//' | \
        sed 's/: /=/' | \
        tr '[:upper:]' '[:lower:]'
    fi
}

# Function to load configuration
load_config() {
    print_info "Loading configuration from $CONFIG_FILE"
    
    while IFS='=' read -r key value; do
        case "$key" in
            PORT)
                export PORT="$value"
                ;;
            AUTH_TOKEN)
                export AUTH_TOKEN="$value"
                ;;
            VALKEY_ADDRESS)
                export VALKEY_ADDRESS="$value"
                ;;
            VALKEY_PASSWORD)
                export VALKEY_PASSWORD="$value"
                ;;
            NETWORK_MODE)
                export NETWORK_MODE="$value"
                ;;
        esac
    done < <(parse_config)
    
    # Set defaults if not set
    export PORT="${PORT:-8080}"
    export VALKEY_ADDRESS="${VALKEY_ADDRESS:-localhost:6379}"
    export NETWORK_MODE="${NETWORK_MODE:-host}"
}

# Function to check if container exists
container_exists() {
    docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Function to check if container is running
container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Function to build the Docker image
build_image() {
    print_info "Building Docker image: $IMAGE_NAME"
    cd "$SCRIPT_DIR"
    docker build -t "$IMAGE_NAME" .
    print_info "Image built successfully"
}

# Function to start the container
start_container() {
    load_config
    
    if container_running; then
        print_warn "Container $CONTAINER_NAME is already running"
        return 0
    fi
    
    if container_exists; then
        print_info "Starting existing container: $CONTAINER_NAME"
        docker start "$CONTAINER_NAME"
    else
        print_info "Creating and starting new container: $CONTAINER_NAME"
        
        # Check if image exists
        if ! docker images --format '{{.Repository}}' | grep -q "^${IMAGE_NAME}$"; then
            print_warn "Image $IMAGE_NAME not found. Building..."
            build_image
        fi
        
        # Build docker run command
        DOCKER_CMD="docker run -d"
        DOCKER_CMD="$DOCKER_CMD --name $CONTAINER_NAME"
        
        # Network mode
        if [ "$NETWORK_MODE" = "host" ]; then
            DOCKER_CMD="$DOCKER_CMD --network host"
        else
            DOCKER_CMD="$DOCKER_CMD -p ${PORT}:${PORT}"
            DOCKER_CMD="$DOCKER_CMD --add-host=host.docker.internal:host-gateway"
        fi
        
        # Environment variables
        DOCKER_CMD="$DOCKER_CMD -e PORT=$PORT"
        DOCKER_CMD="$DOCKER_CMD -e VALKEY_ADDRESS=$VALKEY_ADDRESS"
        # Always pass password, even if empty (Docker handles empty env vars)
        if [ -n "$VALKEY_PASSWORD" ]; then
            DOCKER_CMD="$DOCKER_CMD -e VALKEY_PASSWORD=$VALKEY_PASSWORD"
        fi
        if [ -n "$AUTH_TOKEN" ]; then
            DOCKER_CMD="$DOCKER_CMD -e AUTH_TOKEN=$AUTH_TOKEN"
        fi
        
        # Restart policy
        DOCKER_CMD="$DOCKER_CMD --restart unless-stopped"
        
        # Image name
        DOCKER_CMD="$DOCKER_CMD $IMAGE_NAME"
        
        # Execute the command
        eval "$DOCKER_CMD"
    fi
    
    print_info "Container started successfully"
    print_info "API will be available at http://localhost:${PORT}"
}

# Function to stop the container
stop_container() {
    if ! container_exists; then
        print_warn "Container $CONTAINER_NAME does not exist"
        return 0
    fi
    
    if container_running; then
        print_info "Stopping container: $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME"
        print_info "Container stopped successfully"
    else
        print_warn "Container $CONTAINER_NAME is not running"
    fi
}

# Function to restart the container
restart_container() {
    load_config
    print_info "Restarting container: $CONTAINER_NAME"
    stop_container
    sleep 2
    start_container
}

# Function to remove the container
remove_container() {
    if ! container_exists; then
        print_warn "Container $CONTAINER_NAME does not exist"
        return 0
    fi
    
    stop_container
    print_info "Removing container: $CONTAINER_NAME"
    docker rm "$CONTAINER_NAME"
    print_info "Container removed successfully"
}

# Function to show container status
show_status() {
    if ! container_exists; then
        print_warn "Container $CONTAINER_NAME does not exist"
        return 0
    fi
    
    if container_running; then
        print_info "Container $CONTAINER_NAME is RUNNING"
        echo ""
        docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        print_warn "Container $CONTAINER_NAME is STOPPED"
        echo ""
        docker ps -a --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    fi
}

# Function to show container logs
show_logs() {
    if ! container_exists; then
        print_error "Container $CONTAINER_NAME does not exist"
        exit 1
    fi
    
    docker logs -f "$CONTAINER_NAME"
}

# Function to show configuration
show_config() {
    load_config
    echo ""
    echo "Current Configuration:"
    echo "===================="
    echo "API Port:          $PORT"
    echo "API Auth Token:    ${AUTH_TOKEN:+(set)}${AUTH_TOKEN:-(not set)}"
    echo "Valkey Address:    $VALKEY_ADDRESS"
    echo "Valkey Password:   ${VALKEY_PASSWORD:+(set)}${VALKEY_PASSWORD:-(not set)}"
    echo "Network Mode:      $NETWORK_MODE"
    echo ""
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [command]

Commands:
    start       Start the container
    stop        Stop the container
    restart     Restart the container
    status      Show container status
    logs        Show container logs (follow mode)
    remove      Remove the container
    build       Build the Docker image
    config      Show current configuration
    help        Show this help message

Configuration:
    Edit config.yaml to set:
    - API port and authentication token
    - Valkey server address and password
    - Docker network mode

Examples:
    $0 start        # Start the API container
    $0 logs         # View container logs
    $0 status       # Check container status
    $0 restart      # Restart with new config

EOF
}

# Main script logic
case "${1:-help}" in
    start)
        start_container
        ;;
    stop)
        stop_container
        ;;
    restart)
        restart_container
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    remove)
        remove_container
        ;;
    build)
        build_image
        ;;
    config)
        show_config
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac

