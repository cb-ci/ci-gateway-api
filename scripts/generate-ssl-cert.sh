#!/bin/bash

set -e

current_dir=$(pwd)
SSL_DIR="./ssl"
mkdir -p $SSL_DIR
cd $SSL_DIR
CERT_FILE="server.crt"
KEY_FILE="server.key"
STORE_PW="changeit"

# Ensure variables are set or have defaults for the -subj flag
CJOC_HOST=${CJOC_HOST:-"gateway.acaternberg.flow-training.beescloud.com"}




if ! command -v openssl >/dev/null 2>&1; then
  echo "OpenSSL is not installed."
  exit 1
fi

echo "=== SSL Certificate Generation Script (Automated) ==="

if [[ -f "${CERT_FILE}" && -f "${KEY_FILE}" ]]; then
    echo "✓ SSL certificates exist. Overwriting for automation..."
fi

echo "Generating self-signed SSL certificate..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -subj "/C=US/ST=State/L=City/O=Organization/OU=DevOps/CN=${CJOC_HOST}" \
    -addext "subjectAltName=DNS.1:${CJOC_HOST},DNS.2:${CJOC_HOST},DNS.3:${CJOC_HOST}"

chmod 600 "${KEY_FILE}"
chmod 644 "${CERT_FILE}"

# Copy cacerts

# Create the pem , ${KEY_FILE} is the private key and ${CERT_FILE} is the public key.
# ${KEY_FILE} should not be required in cacert truststore (just the public key is required), but it doesn't hurt to have it for the demo
#cat "${CERT_FILE}" "${KEY_FILE}" > jenkins.pem
cat "${CERT_FILE}" > jenkins.pem


cd "$current_dir"
echo "Done."