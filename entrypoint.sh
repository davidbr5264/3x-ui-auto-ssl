#!/bin/sh

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Pre-flight Checks ---
# Check if the DOMAIN environment variable is set. Caddy needs it.
if [ -z "$DOMAIN" ]; then
    echo "FATAL: The DOMAIN environment variable is not set."
    echo "Please set it to your public domain name."
    exit 1
fi

# Check if the EMAIL environment variable is set. Let's Encrypt recommends it.
if [ -z "$EMAIL" ]; then
    echo "WARNING: The EMAIL environment variable is not set."
    echo "Caddy will proceed without it, but it's recommended for account recovery."
fi

# --- Service Startup ---
# Start the 3x-ui panel in the background.
# It will listen on its default port (2053) inside the container.
# The database will be stored in the /etc/3x-ui volume.
echo "Starting 3x-ui service..."
/usr/local/bin/3x-ui &

# Give 3x-ui a moment to initialize before starting the proxy.
sleep 3

# Start the Caddy web server in the foreground.
# Caddy will read its configuration from /etc/caddy/Caddyfile.
# It will automatically handle SSL for the domain specified in $DOMAIN.
# Caddy's process will keep the container running.
echo "Starting Caddy for domain: $DOMAIN..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
