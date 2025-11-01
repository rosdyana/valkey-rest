# Build stage
FROM golang:1.23-alpine AS builder

WORKDIR /build

# Set Go proxy and environment variables
# Use multiple proxies for redundancy and direct fallback
ENV GOPROXY=https://proxy.golang.org,https://goproxy.cn,direct
ENV GOSUMDB=sum.golang.org
ENV CGO_ENABLED=0

# Copy go mod files first (for better Docker layer caching)
COPY go.mod go.sum* ./

# Download dependencies (only if go.sum exists, otherwise will be handled by go mod tidy)
# Use -x flag to show what's happening for debugging
RUN if [ -f go.sum ]; then \
        go mod download; \
    else \
        echo "go.sum not found, dependencies will be downloaded during go mod tidy"; \
    fi

# Copy source code
COPY . .

# Tidy up dependencies, download, and verify (generates go.sum if missing)
RUN go mod tidy && go mod download && go mod verify

# Build the application
RUN GOOS=linux go build -a -installsuffix cgo -o valkey-rest .

# Runtime stage
FROM alpine:latest

# Install ca-certificates for HTTPS and wget for health check
RUN apk --no-cache add ca-certificates wget

WORKDIR /app

# Copy binary from builder
COPY --from=builder /build/valkey-rest .

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser && \
    chown -R appuser:appuser /app

USER appuser

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Run the application
CMD ["./valkey-rest"]

