# =================================================================
# Dockerfile for 3x-ui with Caddy for Automatic SSL
# =================================================================

# ---- Build Stage ----
# Use the official Golang Alpine image to build the application.
# Using a specific version ensures reproducibility.
FROM golang:1.22-alpine AS builder

# Install build-time dependencies (git)
RUN apk add --no-cache git

# Set the working directory inside the container
WORKDIR /app

# Clone the 3x-ui repository from GitHub
# Cloning the main branch to get the latest version
RUN git clone https://github.com/MHSanaei/3x-ui.git .

# Build the 3x-ui binary
# CGO_ENABLED=0 creates a static binary
# -ldflags="-w -s" strips debug information, making the final binary smaller
RUN CGO_ENABLED=0 go build -o /3x-ui -ldflags="-w -s" .

# ---- Final Stage ----
# Use a minimal Alpine image for the final container to reduce size
FROM alpine:latest

# Add metadata labels to the image
LABEL maintainer="Gemini"
LABEL description="3x-ui with Caddy for automatic SSL certificate provisioning."

# Install runtime dependencies:
# - caddy: The web server for reverse proxy and auto-SSL.
# - ca-certificates: For SSL/TLS connections.
# - wget & unzip: Utilities to download and extract xray-core.
RUN apk add --no-cache caddy ca-certificates wget unzip

# Set the working directory for the application
WORKDIR /opt/3x-ui

# Download and install the latest version of xray-core
# This logic automatically finds the latest release for amd64 architecture.
# If you use ARM (e.g., Raspberry Pi), you'll need to adjust the grep filter.
RUN LATEST_XRAY_URL=$(wget -qO- "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"browser_download_url":' | grep 'linux-64.zip"' | cut -d'"' -f4) && \
    echo "Downloading Xray-core from: $LATEST_XRAY_URL" && \
    wget -O /tmp/xray.zip "$LATEST_XRAY_URL" && \
    unzip /tmp/xray.zip -d /usr/local/bin/ xray geoip.dat geosite.dat && \
    chmod +x /usr/local/bin/xray && \
    rm /tmp/xray.zip

# Copy the built 3x-ui binary from the builder stage
COPY --from=builder /3x-ui /usr/local/bin/3x-ui

# Copy the web assets required by the 3x-ui panel
COPY --from=builder /app/web ./web

# Create directories for persistent data and logs
# /etc/3x-ui: for the 3x-ui database (db/3x-ui.db)
# /etc/caddy/data: for Caddy's state, including SSL certificates
# /var/log: for caddy logs
RUN mkdir -p /etc/3x-ui /etc/caddy/data /var/log

# Copy the Caddyfile configuration and the entrypoint script into the image
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose ports 80 and 443 for Caddy's automatic HTTPS
# Port 80 is used for the ACME HTTP-01 challenge and HTTP-to-HTTPS redirection
# Port 443 is used for HTTPS traffic
EXPOSE 80 443

# Define volumes for persistent data. This ensures your settings and certificates
# are not lost when the container is recreated.
VOLUME ["/etc/3x-ui", "/etc/caddy/data"]

# Set the entrypoint for the container
ENTRYPOINT ["/entrypoint.sh"]
