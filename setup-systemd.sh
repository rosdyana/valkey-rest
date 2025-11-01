#!/bin/bash

# Valkey REST API Systemd Service Setup Script
# This interactive script sets up the Valkey REST API as a systemd service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="valkey-rest"
INSTALL_DIR="/opt/valkey-rest"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BINARY_NAME="valkey-rest"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local missing=0
    
    # Check for Go
    if ! command_exists go; then
        print_error "Go is not installed"
        echo "  Install Go 1.21 or later:"
        echo "    sudo apt update && sudo apt install -y golang-go"
        echo "    or visit: https://go.dev/dl/"
        missing=1
    else
        GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
        print_info "Go found: $(go version)"
        
        # Check if Go version is >= 1.21
        REQUIRED_VERSION="1.21"
        if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$GO_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
            print_warn "Go version $GO_VERSION may be too old. Recommended: 1.21 or later"
        fi
    fi
    
    # Check for systemd
    if ! command_exists systemctl; then
        print_error "systemd is not available"
        missing=1
    else
        print_info "systemd found"
    fi
    
    if [ $missing -eq 1 ]; then
        print_error "Please install missing prerequisites before continuing"
        exit 1
    fi
    
    print_info "All prerequisites satisfied"
    echo ""
}

# Function to prompt for configuration
get_configuration() {
    print_header "Configuration"
    echo "Please provide the following configuration:"
    echo ""
    
    # Port
    read -p "API Port [8080]: " PORT
    PORT=${PORT:-8080}
    
    # Validate port
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        print_error "Invalid port number. Using default 8080"
        PORT=8080
    fi
    
    # Valkey Address
    read -p "Valkey Server Address [localhost:6379]: " VALKEY_ADDRESS
    VALKEY_ADDRESS=${VALKEY_ADDRESS:-localhost:6379}
    
    # Valkey Password
    echo ""
    read -sp "Valkey Password (press Enter if none): " VALKEY_PASSWORD
    echo ""
    
    # Auth Token
    echo ""
    echo "Authentication Token (required for API security)"
    echo "Generate a secure token with: openssl rand -hex 32"
    read -sp "Enter AUTH_TOKEN (press Enter to generate one): " AUTH_TOKEN
    echo ""
    
    if [ -z "$AUTH_TOKEN" ]; then
        if command_exists openssl; then
            AUTH_TOKEN=$(openssl rand -hex 32)
            print_info "Generated AUTH_TOKEN: $AUTH_TOKEN"
            echo "  (Save this token securely!)"
        else
            print_warn "openssl not found. Please provide a token manually."
            read -sp "Enter AUTH_TOKEN: " AUTH_TOKEN
            echo ""
            if [ -z "$AUTH_TOKEN" ]; then
                print_error "AUTH_TOKEN is required"
                exit 1
            fi
        fi
    fi
    
    # Service User
    echo ""
    read -p "Service User [www-data]: " SERVICE_USER
    SERVICE_USER=${SERVICE_USER:-www-data}
    
    # Verify user exists
    if ! id "$SERVICE_USER" &>/dev/null; then
        print_warn "User $SERVICE_USER does not exist. Creating user..."
        useradd -r -s /bin/false "$SERVICE_USER" 2>/dev/null || {
            print_error "Failed to create user $SERVICE_USER"
            exit 1
        }
    fi
    
    # Environment File Option
    echo ""
    read -p "Store secrets in environment file? (y/n) [n]: " USE_ENV_FILE
    USE_ENV_FILE=${USE_ENV_FILE:-n}
    
    ENV_FILE=""
    if [[ "$USE_ENV_FILE" =~ ^[Yy]$ ]]; then
        ENV_FILE="${INSTALL_DIR}/.env"
        print_info "Secrets will be stored in $ENV_FILE"
    else
        print_warn "Secrets will be embedded in systemd service file"
    fi
    
    echo ""
    print_info "Configuration summary:"
    echo "  Port: $PORT"
    echo "  Valkey Address: $VALKEY_ADDRESS"
    echo "  Valkey Password: ${VALKEY_PASSWORD:+**(set)**}${VALKEY_PASSWORD:-(not set)}"
    echo "  Auth Token: ${AUTH_TOKEN:0:16}... (hidden)"
    echo "  Service User: $SERVICE_USER"
    echo "  Install Directory: $INSTALL_DIR"
    echo ""
    
    read -p "Continue with this configuration? (y/n) [y]: " CONFIRM
    CONFIRM=${CONFIRM:-y}
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Setup cancelled"
        exit 0
    fi
}

# Function to build the binary
build_binary() {
    print_header "Building Binary"
    
    cd "$SCRIPT_DIR"
    
    # Check if go.mod exists
    if [ ! -f "go.mod" ]; then
        print_error "go.mod not found in $SCRIPT_DIR"
        exit 1
    fi
    
    # Download dependencies
    print_info "Downloading Go dependencies..."
    if ! go mod download; then
        print_error "Failed to download dependencies"
        exit 1
    fi
    
    # Build the binary
    print_info "Building binary..."
    if ! CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o "$BINARY_NAME" .; then
        print_error "Failed to build binary"
        exit 1
    fi
    
    # Verify binary exists
    if [ ! -f "$BINARY_NAME" ]; then
        print_error "Binary $BINARY_NAME was not created"
        exit 1
    fi
    
    print_info "Binary built successfully: $BINARY_NAME"
    echo ""
}

# Function to create installation directory
create_install_dir() {
    print_header "Creating Installation Directory"
    
    if [ -d "$INSTALL_DIR" ]; then
        print_warn "Directory $INSTALL_DIR already exists"
        read -p "Remove existing directory? (y/n) [n]: " REMOVE_DIR
        REMOVE_DIR=${REMOVE_DIR:-n}
        
        if [[ "$REMOVE_DIR" =~ ^[Yy]$ ]]; then
            print_info "Removing existing directory..."
            rm -rf "$INSTALL_DIR"
        else
            print_info "Using existing directory"
        fi
    fi
    
    mkdir -p "$INSTALL_DIR"
    print_info "Created directory: $INSTALL_DIR"
    echo ""
}

# Function to create environment file
create_env_file() {
    if [ -n "$ENV_FILE" ]; then
        print_info "Creating environment file: $ENV_FILE"
        cat > "$ENV_FILE" <<EOF
# Valkey REST API Environment Variables
# This file contains sensitive information. Restrict permissions with: chmod 600

PORT=$PORT
VALKEY_ADDRESS=$VALKEY_ADDRESS
VALKEY_PASSWORD=$VALKEY_PASSWORD
AUTH_TOKEN=$AUTH_TOKEN
EOF
        chmod 600 "$ENV_FILE"
        chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
        print_info "Environment file created with restricted permissions"
    fi
}

# Function to create systemd service file
create_service_file() {
    print_header "Creating Systemd Service File"
    
    # Build Environment section
    ENV_SECTION=""
    if [ -n "$ENV_FILE" ]; then
        ENV_SECTION="EnvironmentFile=$ENV_FILE"
    else
        ENV_SECTION="Environment=\"PORT=$PORT\"
Environment=\"VALKEY_ADDRESS=$VALKEY_ADDRESS\""
        
        if [ -n "$VALKEY_PASSWORD" ]; then
            ENV_SECTION="$ENV_SECTION
Environment=\"VALKEY_PASSWORD=$VALKEY_PASSWORD\""
        fi
        
        ENV_SECTION="$ENV_SECTION
Environment=\"AUTH_TOKEN=$AUTH_TOKEN\""
    fi
    
    # Create service file
    print_info "Creating service file: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Valkey REST API
Documentation=https://github.com/valkey-io/valkey-go
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$BINARY_NAME
$ENV_SECTION
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    print_info "Service file created"
    echo ""
}

# Function to install files
install_files() {
    print_header "Installing Files"
    
    # Copy binary
    print_info "Copying binary to $INSTALL_DIR..."
    cp "$SCRIPT_DIR/$BINARY_NAME" "$INSTALL_DIR/"
    
    # Set permissions
    print_info "Setting permissions..."
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR/$BINARY_NAME"
    
    # Set executable bit on directory
    chmod 755 "$INSTALL_DIR"
    
    print_info "Files installed successfully"
    echo ""
}

# Function to enable and start service
enable_service() {
    print_header "Enabling Systemd Service"
    
    # Reload systemd
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload
    
    # Enable service
    print_info "Enabling $SERVICE_NAME service..."
    systemctl enable "$SERVICE_NAME"
    
    # Start service
    print_info "Starting $SERVICE_NAME service..."
    if systemctl start "$SERVICE_NAME"; then
        print_info "Service started successfully"
    else
        print_error "Failed to start service"
        print_info "Check logs with: journalctl -u $SERVICE_NAME -n 50"
        exit 1
    fi
    
    echo ""
}

# Function to verify installation
verify_installation() {
    print_header "Verifying Installation"
    
    # Check service status
    print_info "Service status:"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
    echo ""
    
    # Wait a moment for service to start
    sleep 2
    
    # Test health endpoint
    print_info "Testing health endpoint..."
    if command_exists curl; then
        if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
            print_info "✓ Health check passed"
            curl -s "http://localhost:$PORT/health" | python3 -m json.tool 2>/dev/null || curl -s "http://localhost:$PORT/health"
            echo ""
        else
            print_warn "Health check failed. Service may still be starting..."
            print_info "Check logs with: journalctl -u $SERVICE_NAME -f"
        fi
    else
        print_warn "curl not available. Skipping health check"
    fi
    
    echo ""
}

# Function to show completion message
show_completion() {
    print_header "Installation Complete!"
    
    echo "The Valkey REST API has been successfully installed as a systemd service."
    echo ""
    echo "Useful commands:"
    echo "  Start service:   sudo systemctl start $SERVICE_NAME"
    echo "  Stop service:    sudo systemctl stop $SERVICE_NAME"
    echo "  Restart service: sudo systemctl restart $SERVICE_NAME"
    echo "  View status:     sudo systemctl status $SERVICE_NAME"
    echo "  View logs:       sudo journalctl -u $SERVICE_NAME -f"
    echo "  View logs (n):   sudo journalctl -u $SERVICE_NAME -n 50"
    echo ""
    echo "Service Details:"
    echo "  Service Name: $SERVICE_NAME"
    echo "  Install Dir:  $INSTALL_DIR"
    echo "  Binary:       $INSTALL_DIR/$BINARY_NAME"
    echo "  Config:       $SERVICE_FILE"
    if [ -n "$ENV_FILE" ]; then
        echo "  Env File:     $ENV_FILE"
    fi
    echo "  API Port:     $PORT"
    echo "  API URL:      http://localhost:$PORT"
    echo ""
    
    if [ -z "$ENV_FILE" ]; then
        print_warn "Security Note: Secrets are embedded in the service file."
        print_info "Consider using an environment file for better security."
        echo "  To use an env file, edit $SERVICE_FILE and add:"
        echo "    EnvironmentFile=$INSTALL_DIR/.env"
        echo "  Then create $INSTALL_DIR/.env with your secrets"
    fi
    
    echo ""
    print_info "Your AUTH_TOKEN (save this securely!):"
    echo "  $AUTH_TOKEN"
    echo ""
}

# Main execution
main() {
    clear
    print_header "Valkey REST API - Systemd Service Setup"
    echo ""
    
    # Check if running as root
    check_root
    
    # Run setup steps
    check_prerequisites
    get_configuration
    build_binary
    create_install_dir
    create_env_file
    create_service_file
    install_files
    enable_service
    verify_installation
    show_completion
}

# Run main function
main "$@"

