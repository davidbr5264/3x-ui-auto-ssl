#!/bin/bash

# Start the 3x-ui panel in the background.
# The '&' symbol detaches the process, allowing the script to continue.
echo "Starting 3x-ui panel..."
/opt/3x-ui/3x-ui &

# Start Caddy in the foreground.
# Caddy will read its configuration from the specified Caddyfile.
# The '--adapter caddyfile' ensures Caddy interprets the file as a Caddyfile.
# This command keeps the Docker container running.
echo "Starting Caddy server..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

# Wait for any process to exit, then exit.
wait -n
exit $?
