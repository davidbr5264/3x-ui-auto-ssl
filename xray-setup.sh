#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[*]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root"
    exit 1
fi

# Generate random UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# Get public IP
PUBLIC_IP=$(curl -s https://api.ipify.org)

# Generate random paths
WS_PATH="/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 10)"

# Ask for domain
echo
print_warning "Please make sure your domain is pointing to this server's IP: $PUBLIC_IP"
read -p "Enter your domain name (e.g., example.com): " DOMAIN

# Check if port 80 is in use and stop conflicting services
print_status "Checking for services using port 80..."
if lsof -i :80 >/dev/null 2>&1; then
    print_warning "Port 80 is already in use. Stopping conflicting services..."
    
    # Stop common services that might use port 80
    systemctl stop nginx apache2 lighttpd httpd >/dev/null 2>&1
    pkill -f "python.*80" >/dev/null 2>&1
    pkill -f "node.*80" >/dev/null 2>&1
    
    # Wait a moment and check again
    sleep 2
    if lsof -i :80 >/dev/null 2>&1; then
        print_error "Could not free port 80. Please manually stop the service using port 80 and run the script again."
        print_info "You can check what's using port 80 with: sudo lsof -i :80"
        exit 1
    fi
fi

# Install dependencies
print_status "Installing dependencies..."
apt update && apt upgrade -y
apt install -y curl wget unzip certbot nginx

# Stop nginx temporarily for certbot
systemctl stop nginx >/dev/null 2>&1

# Install Xray
print_status "Installing Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Create SSL certificate using standalone method
print_status "Creating SSL certificate using standalone method..."
certbot certonly --standalone --agree-tos --register-unsafely-without-email -d $DOMAIN --non-interactive

if [ $? -ne 0 ]; then
    print_error "SSL certificate creation failed!"
    print_info "Common issues:"
    print_info "1. Domain not pointing to this server's IP"
    print_info "2. Port 80 still in use by another process"
    print_info "3. Firewall blocking port 80"
    exit 1
fi

# Fix certificate permissions
print_status "Fixing SSL certificate permissions..."
chmod 755 /etc/letsencrypt/{live,archive}
chmod 755 /etc/letsencrypt/live/$DOMAIN
chmod 644 /etc/letsencrypt/live/$DOMAIN/*.pem
chmod 755 /etc/letsencrypt/archive/$DOMAIN
chmod 644 /etc/letsencrypt/archive/$DOMAIN/*.pem

# Create Xray config with proper certificate paths
print_status "Creating Xray configuration..."
cat > /usr/local/etc/xray/config.json << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": 10000,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificateFile": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
                            "keyFile": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
                        }
                    ]
                },
                "wsSettings": {
                    "path": "$WS_PATH"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {}
        },
        {
            "protocol": "blackhole",
            "settings": {},
            "tag": "blocked"
        }
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "blocked"
            }
        ]
    }
}
EOF

# Fix Xray service permissions
print_status "Fixing Xray service permissions..."
if [ -f /etc/systemd/system/xray.service ]; then
    # Change Xray user to root for certificate access
    sed -i 's/User=nobody/User=root/' /etc/systemd/system/xray.service
    sed -i 's/Group=nobody/Group=root/' /etc/systemd/system/xray.service
    systemctl daemon-reload
fi

# Create Nginx config for CDN
print_status "Configuring Nginx for CDN..."
cat > /etc/nginx/sites-available/xray << EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;

    location $WS_PATH {
        proxy_redirect off;
        proxy_pass https://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        return 404;
    }
}
EOF

# Enable Nginx site
ln -sf /etc/nginx/sites-available/xray /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create webroot for ACME challenges
mkdir -p /var/www/html
chown -R www-data:www-data /var/www/html

# Restart services
print_status "Restarting services..."
systemctl restart nginx
systemctl restart xray
systemctl enable nginx xray

# Check if services are running
print_status "Checking service status..."
if systemctl is-active --quiet xray; then
    print_status "Xray service is running successfully!"
else
    print_error "Xray service failed to start. Checking logs..."
    journalctl -u xray -n 10 --no-pager
    print_info "Trying alternative approach..."
    
    # Alternative: Copy certificates to Xray directory
    mkdir -p /usr/local/etc/xray/ssl
    cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /usr/local/etc/xray/ssl/
    cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /usr/local/etc/xray/ssl/
    chmod 644 /usr/local/etc/xray/ssl/*.pem
    
    # Update config to use local copies
    sed -i 's|/etc/letsencrypt/live/$DOMAIN|/usr/local/etc/xray/ssl|g' /usr/local/etc/xray/config.json
    systemctl restart xray
fi

if systemctl is-active --quiet nginx; then
    print_status "Nginx service is running successfully!"
else
    print_error "Nginx service failed to start."
    journalctl -u nginx -n 10 --no-pager
fi

# Generate client config
print_status "Generating client configuration..."
cat > xray-client-config.txt << EOF
=============================================
VLESS + WS + TLS + CDN Configuration
=============================================

Server: $DOMAIN
Port: 443
UUID: $UUID
Transport: WebSocket (WS)
Path: $WS_PATH
TLS: Enabled
SNI: $DOMAIN
Flow: xtls-rprx-vision

Xray Client Configuration (V2RayN, etc.):
vless://$UUID@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$DOMAIN&type=ws&path=${WS_PATH}#Xray-VLESS-WS-TLS

QR Code for V2RayN:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$(echo -n "vless://$UUID@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$DOMAIN&type=ws&path=${WS_PATH}#Xray-VLESS-WS-TLS" | jq -s -R -r @uri)

Clash Configuration:
- name: Xray-VLESS-WS-TLS
  type: vless
  server: $DOMAIN
  port: 443
  uuid: $UUID
  tls: true
  servername: $DOMAIN
  network: ws
  ws-opts:
    path: $WS_PATH
  flow: xtls-rprx-vision

For CDN (Cloudflare):
1. Enable proxy (orange cloud) for your domain in Cloudflare
2. Make sure SSL/TLS encryption mode is set to "Full"
3. Use the same configuration as above

Test command:
curl -x http://127.0.0.1:10809 https://www.google.com

EOF

print_status "Installation completed!"
print_warning "Client configuration saved to: xray-client-config.txt"
print_warning "Please check the file for connection details"

# Test connection
print_status "Testing configuration..."
sleep 3
if systemctl is-active --quiet xray && systemctl is-active --quiet nginx; then
    print_status "All services are running successfully!"
    print_info "You can check Xray logs with: journalctl -u xray -f"
    print_info "You can check Nginx logs with: journalctl -u nginx -f"
else
    print_warning "Some services may not be running properly. Please check:"
    print_info "systemctl status xray"
    print_info "systemctl status nginx"
fi
