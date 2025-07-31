# Use a lightweight Debian base image
FROM debian:stable-slim

# Set environment variables for 3x-ui port and directories
ENV XUI_PORT=2053
ENV XUI_DIR=/opt/3x-ui
ENV CADDY_FILE=/etc/caddy/Caddyfile

# Install necessary packages:
# curl, wget, unzip for downloading and extracting 3x-ui
# git (optional, but good for general use)
# supervisor (to manage multiple processes, though a simple script is used here)
# ca-certificates for HTTPS
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    wget \
    unzip \
    git \
    supervisor \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Caddy from its official repository
# This ensures you get the latest stable version of Caddy.
# For more details, see: https://caddyserver.com/docs/install#debian-ubuntu-raspbian
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install -y caddy

# Define build arguments for 3x-ui version and architecture
# You should replace these with the desired version and your server's architecture (e.g., amd64, arm64, armv7)
ARG XUI_VERSION="v2.1.0" # <<< IMPORTANT: Replace with the latest stable 3x-ui version
ARG XUI_ARCH="amd64"    # <<< IMPORTANT: Replace with your server's CPU architecture

# Download and install 3x-ui
# Creates the directory, downloads the specified version, unzips it,
# removes the zip file, and makes the 3x-ui executable.
RUN mkdir -p ${XUI_DIR} && \
    wget -O /tmp/3x-ui.zip "https://github.com/MHSanaei/3x-ui/releases/download/${XUI_VERSION}/3x-ui-linux-${XUI_ARCH}.zip" && \
    unzip /tmp/3x-ui.zip -d ${XUI_DIR} && \
    rm /tmp/3x-ui.zip && \
    chmod +x ${XUI_DIR}/3x-ui

# Copy the Caddyfile into the Docker image
# This file configures Caddy for reverse proxy and SSL.
COPY Caddyfile ${CADDY_FILE}

# Copy the startup script into the Docker image and make it executable
# This script will start both 3x-ui and Caddy.
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Expose the necessary ports:
# 80 (HTTP) and 443 (HTTPS) for Caddy to handle web traffic and SSL.
# XUI_PORT for 3x-ui's internal listening port (default 2053).
EXPOSE 80
EXPOSE 443
EXPOSE ${XUI_PORT}

# Set the working directory for the container
WORKDIR ${XUI_DIR}

# Define the command to run when the container starts
# This executes the start.sh script.
CMD ["/usr/local/bin/start.sh"]
