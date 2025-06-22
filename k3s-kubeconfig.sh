#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Check if tailscale is installed
if ! command -v tailscale &> /dev/null; then
    echo "Error: tailscale is not installed"
    exit 1
fi

# Get Tailscale IPv4 address
TAILSCALE_IP=$(tailscale ip | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

if [ -z "$TAILSCALE_IP" ]; then
    echo "Error: Could not get Tailscale IPv4 address"
    exit 1
fi

# Update k3s service file
K3S_SERVICE_FILE="/etc/systemd/system/k3s.service"

if [ ! -f "$K3S_SERVICE_FILE" ]; then
    echo "Error: k3s service file not found at $K3S_SERVICE_FILE"
    exit 1
fi

# Create backup of original service file
cp "$K3S_SERVICE_FILE" "${K3S_SERVICE_FILE}.backup"

# Check if this TLS-SAN entry already exists
if ! grep -q "\'--tls-san=${TAILSCALE_IP}\'" "$K3S_SERVICE_FILE"; then
    # Add new TLS-SAN entry before the last line with exactly 8 spaces indentation
    sed -i "$ i\\        '--tls-san=${TAILSCALE_IP}' \\" "$K3S_SERVICE_FILE"
fi

# Ensure the .kube directory exists
mkdir -p ~/.kube

# Copy the base k3s config
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config

# Get the certificate authority data and other credentials from the original file
CA_DATA=$(grep 'certificate-authority-data:' /etc/rancher/k3s/k3s.yaml | head -n1 | awk '{print $2}')
CERT_DATA=$(grep 'client-certificate-data:' /etc/rancher/k3s/k3s.yaml | awk '{print $2}')
KEY_DATA=$(grep 'client-key-data:' /etc/rancher/k3s/k3s.yaml | awk '{print $2}')

# Create a temporary file for the new config
TEMP_FILE=$(mktemp)

# Write the new configuration
cat > "$TEMP_FILE" << EOF
apiVersion: v1
kind: Config
preferences: {}
clusters:
- name: default
  cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://127.0.0.1:6443
- name: tailscale
  cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://${TAILSCALE_IP}:6443
users:
- name: default
  user:
    client-certificate-data: ${CERT_DATA}
    client-key-data: ${KEY_DATA}
contexts:
- name: default
  context:
    cluster: default
    user: default
- name: tailscale
  context:
    cluster: tailscale
    user: default
current-context: tailscale
EOF

# Replace the existing config with the new one
mv "$TEMP_FILE" ~/.kube/config

# Set proper permissions
chmod 600 ~/.kube/config

# Now reload systemd and restart k3s
echo "Reloading systemd and restarting k3s..."
systemctl daemon-reload
systemctl restart k3s

echo "Setup completed:"
echo "1. K3s service file updated with additional TLS-SAN: ${TAILSCALE_IP}"
echo "2. Kubeconfig updated with Tailscale configuration"
echo "3. K3s service restarted"
echo "Please wait a few moments for k3s to be fully ready"
