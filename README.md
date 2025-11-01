# Valkey REST API

A minimal, lightweight, and secure REST API for Valkey built with Go. This API provides HTTP endpoints to interact with a Valkey server using the [valkey-go](https://github.com/valkey-io/valkey-go) client library.

## Project Structure

```
valkey-rest/
├── main.go                 # Main API application
├── Dockerfile              # Docker image definition
├── docker-compose.yml      # Docker Compose configuration (optional)
├── manage.sh              # Docker management script (recommended)
├── config.yaml.example    # Configuration template
├── go.mod                 # Go dependencies
└── README.md              # This file
```

**Key Files:**
- `manage.sh` - Easy-to-use bash script for container management
- `config.yaml` - Your configuration file (copy from `config.yaml.example`)
- `config.yaml.example` - Template configuration file

## Features

- ✅ Minimal and lightweight design
- ✅ Secure defaults (non-root user, timeouts, input validation)
- ✅ **Token-based authentication** for protected endpoints
- ✅ Containerized with Docker
- ✅ Health check endpoint
- ✅ Basic CRUD operations (GET, SET, DELETE)
- ✅ Key listing with pattern matching
- ✅ Graceful shutdown
- ✅ Environment-based configuration

## API Endpoints

> **Note:** All endpoints except `/health` require authentication via the `Authorization` header. See [Authentication](#authentication) section below.

### Health Check
```http
GET /health
```
Returns the health status of the API and Valkey connection. This endpoint does **not** require authentication.

### Get Value
```http
GET /keys/{key}
Authorization: Bearer <your-token>
```
Retrieves the value for a specific key.

**Response (200 OK):**
```json
{
  "key": "mykey",
  "value": "myvalue"
}
```

**Response (404 Not Found):**
```json
{
  "error": "key not found"
}
```

### Set Value
```http
POST /keys/{key}
Authorization: Bearer <your-token>
Content-Type: application/json

{
  "value": "myvalue",
  "expiration": 3600
}
```
Sets a value for a key. `expiration` is optional and specified in seconds.

**Response (201 Created):**
```json
{
  "status": "created",
  "key": "mykey"
}
```

### Delete Key
```http
DELETE /keys/{key}
Authorization: Bearer <your-token>
```
Deletes a key.

**Response (200 OK):**
```json
{
  "status": "deleted",
  "key": "mykey"
}
```

**Response (404 Not Found):**
```json
{
  "error": "key not found"
}
```

### List Keys
```http
GET /keys?pattern=*&limit=100
Authorization: Bearer <your-token>
```
Lists keys matching a pattern. Query parameters:
- `pattern`: Pattern to match (default: `*`)
- `limit`: Maximum number of keys to return (default: 100, max: 1000)

**Response (200 OK):**
```json
{
  "keys": ["key1", "key2", "key3"],
  "count": 3
}
```

## Authentication

The API uses token-based authentication for all endpoints except `/health`. 

### Setting the Token

Set the `AUTH_TOKEN` environment variable when running the API:

```bash
export AUTH_TOKEN="your-secret-token-here"
```

### Using the Token

Include the token in the `Authorization` header:

```bash
# Using Bearer token format (recommended)
curl -H "Authorization: Bearer your-secret-token-here" \
  http://localhost:8080/keys/mykey

# Or directly as the token
curl -H "Authorization: your-secret-token-here" \
  http://localhost:8080/keys/mykey
```

**Note:** If `AUTH_TOKEN` is not set, the API will run without authentication (not recommended for production).

## Configuration

The API can be configured in two ways:

### Method 1: Configuration File (Recommended)

Edit `config.yaml` file:

```yaml
api:
  port: 8080
  auth_token: "your-secret-api-token-here"

valkey:
  address: "localhost:6379"
  password: "your-valkey-password"  # Leave empty "" if no password required

docker:
  network_mode: "host"  # or "bridge"
```

The `manage.sh` script automatically reads from this file.

### Method 2: Environment Variables

You can also configure using environment variables (used by Docker directly):

- `PORT`: Server port (default: `8080`)
- `VALKEY_ADDRESS`: Valkey server address (default: `localhost:6379`)
  - For Docker containers accessing host Valkey: use `host.docker.internal:6379` or the host's IP
  - For native Debian deployment: use `localhost:6379` or `127.0.0.1:6379`
- `VALKEY_PASSWORD`: Password for authenticating with Valkey server (required if Valkey is password-protected)
- `AUTH_TOKEN`: Authentication token for protecting endpoints (optional but recommended)

## Quick Start

### Using Management Script (Recommended)

The easiest way to manage the API is using the provided `manage.sh` script with a `config.yaml` file.

1. **Copy the example config file:**
```bash
cp config.yaml.example config.yaml
```

2. **Edit `config.yaml` with your settings:**
```yaml
api:
  port: 8080
  auth_token: "your-secret-api-token-here"

valkey:
  address: "localhost:6379"
  password: "your-valkey-password"  # Leave empty "" if no password

docker:
  network_mode: "host"  # or "bridge"
```

3. **Start the API:**
```bash
./manage.sh start
```

4. **Check status:**
```bash
./manage.sh status
```

5. **View logs:**
```bash
./manage.sh logs
```

**Available commands:**
- `./manage.sh start` - Start the container
- `./manage.sh stop` - Stop the container
- `./manage.sh restart` - Restart the container
- `./manage.sh status` - Show container status
- `./manage.sh logs` - View container logs
- `./manage.sh remove` - Remove the container
- `./manage.sh build` - Build the Docker image
- `./manage.sh config` - Show current configuration

**Note:** The script requires Python3 (with PyYAML) or `yq` for optimal YAML parsing, but will fall back to a simple parser if neither is available.

### Using Docker Compose

1. Clone or download this repository
2. Set your authentication token:
```bash
export AUTH_TOKEN="your-secret-token-here"
```
3. Set the Valkey password (if your Valkey server requires authentication):
```bash
export VALKEY_PASSWORD="your-valkey-password"
```
4. Set the Valkey address (if different from default):
```bash
export VALKEY_ADDRESS="host.docker.internal:6379"  # For Valkey on host
# or
export VALKEY_ADDRESS="192.168.1.100:6379"  # For Valkey on specific IP
```
5. Run with Docker Compose:
```bash
docker-compose up -d
```

**Note:** This assumes Valkey is already running on your Debian server. The API will connect to it.

### Using Docker

1. Build the image:
```bash
docker build -t valkey-rest .
```

2. Run the container (assuming Valkey is running on the host):
```bash
docker run -p 8080:8080 \
  -e VALKEY_ADDRESS=host.docker.internal:6379 \
  -e VALKEY_PASSWORD=your-valkey-password \
  -e AUTH_TOKEN=your-secret-token-here \
  --add-host=host.docker.internal:host-gateway \
  valkey-rest
```

Or using host network mode (Linux only):
```bash
docker run -p 8080:8080 \
  --network host \
  -e VALKEY_ADDRESS=localhost:6379 \
  -e VALKEY_PASSWORD=your-valkey-password \
  -e AUTH_TOKEN=your-secret-token-here \
  valkey-rest
```

### Local Development

1. Install Go 1.21 or later
2. Install dependencies:
```bash
go mod download
```

3. Run the application:
```bash
PORT=8080 \
VALKEY_ADDRESS=localhost:6379 \
VALKEY_PASSWORD=your-valkey-password \
AUTH_TOKEN=your-secret-token-here \
go run main.go
```

## Deployment to Debian Server

This guide assumes you already have Valkey running on your Debian server (not in Docker).

### Option 1: Using Management Script (Easiest)

1. **Install Docker on your Debian server:**
```bash
sudo apt update
sudo apt install -y docker.io python3 python3-pip
sudo systemctl enable docker
sudo systemctl start docker
```

2. **Install PyYAML for config parsing (optional but recommended):**
```bash
sudo pip3 install pyyaml
```

3. **Copy project files to your server:**
```bash
scp -r . user@your-server:/opt/valkey-rest/
```

4. **On the server, configure the API:**
```bash
cd /opt/valkey-rest
cp config.yaml.example config.yaml
nano config.yaml  # Edit with your settings
```

5. **Start the API:**
```bash
chmod +x manage.sh
./manage.sh build    # Build the Docker image
./manage.sh start    # Start the container
```

6. **Verify it's running:**
```bash
./manage.sh status
curl http://localhost:8080/health
```

### Option 2: Using Docker Compose

1. Install Docker on your Debian server:
```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin
sudo systemctl enable docker
sudo systemctl start docker
```

2. Copy the project files to your server (or clone the repository)

3. Set your environment variables. Create a `.env` file or export them:
```bash
export AUTH_TOKEN="your-secret-token-here"
export VALKEY_PASSWORD="your-valkey-password"  # Required if Valkey has password
export VALKEY_ADDRESS="localhost:6379"  # or the IP where Valkey is running
```

4. Build and run:
```bash
docker-compose up -d --build
```

5. Verify the API is running:
```bash
curl http://localhost:8080/health
```

### Option 3: Using Docker without Docker Compose

1. Build the image:
```bash
docker build -t valkey-rest .
```

2. Run the API (assuming Valkey is running on the host):
```bash
docker run -d --name valkey-rest-api \
  -p 8080:8080 \
  --network host \
  -e VALKEY_ADDRESS=localhost:6379 \
  -e VALKEY_PASSWORD=your-valkey-password \
  -e AUTH_TOKEN=your-secret-token-here \
  valkey-rest
```

Or if you need to access Valkey via IP:
```bash
docker run -d --name valkey-rest-api \
  -p 8080:8080 \
  -e VALKEY_ADDRESS=192.168.1.100:6379 \
  -e VALKEY_PASSWORD=your-valkey-password \
  -e AUTH_TOKEN=your-secret-token-here \
  --add-host=host.docker.internal:host-gateway \
  valkey-rest
```

### Option 4: Systemd Service (Native Binary)

1. Build the binary:
```bash
CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o valkey-rest
```

2. Create a systemd service file `/etc/systemd/system/valkey-rest.service`:
```ini
[Unit]
Description=Valkey REST API
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/valkey-rest
ExecStart=/opt/valkey-rest/valkey-rest
Environment="PORT=8080"
Environment="VALKEY_ADDRESS=localhost:6379"
Environment="VALKEY_PASSWORD=your-valkey-password"
Environment="AUTH_TOKEN=your-secret-token-here"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

3. Copy the binary and start the service:
```bash
sudo mkdir -p /opt/valkey-rest
sudo cp valkey-rest /opt/valkey-rest/
sudo chown -R www-data:www-data /opt/valkey-rest
sudo systemctl daemon-reload
sudo systemctl enable valkey-rest
sudo systemctl start valkey-rest
```

**Security Note:** For production, consider storing the `AUTH_TOKEN` in a secure file and using systemd's `EnvironmentFile` directive instead of embedding it in the service file.

## Security Considerations

- ✅ **Token-based authentication** - All data operations require a valid token
- ✅ The Docker container runs as a non-root user
- ✅ Input validation on all endpoints
- ✅ Timeout protection for all requests
- ✅ No sensitive information in error messages
- ✅ Health check endpoint for monitoring (public, no auth required)

### Token Security Best Practices

1. **Use strong tokens**: Generate a secure random token:
   ```bash
   openssl rand -hex 32
   ```

2. **Never commit tokens**: Add `.env` to `.gitignore` if using environment files

3. **Rotate tokens regularly**: Change your `AUTH_TOKEN` periodically

4. **Use HTTPS in production**: If exposing the API externally, use a reverse proxy (nginx, Traefik) with SSL/TLS

## Building from Source

```bash
go mod download
go build -o valkey-rest main.go
```

## Testing

Example API calls (replace `your-token` with your actual token):

```bash
# Health check (no auth required)
curl http://localhost:8080/health

# Set a value (requires token)
curl -X POST http://localhost:8080/keys/test \
  -H "Authorization: Bearer your-token" \
  -H "Content-Type: application/json" \
  -d '{"value": "Hello World", "expiration": 3600}'

# Get a value (requires token)
curl -H "Authorization: Bearer your-token" \
  http://localhost:8080/keys/test

# List keys (requires token)
curl -H "Authorization: Bearer your-token" \
  "http://localhost:8080/keys?pattern=*&limit=10"

# Delete a key (requires token)
curl -X DELETE \
  -H "Authorization: Bearer your-token" \
  http://localhost:8080/keys/test
```

### Testing Authentication

```bash
# This should fail with 401 Unauthorized
curl http://localhost:8080/keys/test

# Expected response:
# {"error":"authorization token required"}

# This should fail with invalid token
curl -H "Authorization: Bearer wrong-token" \
  http://localhost:8080/keys/test

# Expected response:
# {"error":"invalid authorization token"}
```

## License

This project is provided as-is for your use.

