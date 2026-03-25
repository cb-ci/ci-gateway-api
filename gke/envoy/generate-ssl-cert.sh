#!/bin/bash
# Generates a self-signed TLS certificate for local/dev use.
# For production, replace jenkins.pem and server.key with CA-signed certificates.

set -eo pipefail

DOMAIN=${1:-gateway.acaternberg.flow-training.beescloud.com}
DAYS=${2:-365}

echo "Generating self-signed certificate for domain: ${DOMAIN}"

openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout server.key \
  -out jenkins.pem \
  -days "${DAYS}" \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}"

echo "Certificate generated:"
echo "  Certificate: jenkins.pem"
echo "  Private Key: server.key"
echo "  Valid for:   ${DAYS} days"
