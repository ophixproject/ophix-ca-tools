#!/bin/bash
set -e

# Load .env
if [ ! -f .env ]; then
    echo "Missing .env. Run init_ca.sh first."
    exit 1
fi
set -a
source .env
set +a

if [ -z "$CA_CONFIG" ]; then
    echo "CA_CONFIG not set in .env"
    exit 1
fi

# Extract CA paths from config
CA_DIR=$(awk -F= '/^dir[ ]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' "$CA_CONFIG")
CA_CERT=$(awk -F= '/^certificate[ ]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' "$CA_CONFIG")
expand_dir() { echo "${1/\$dir/$CA_DIR}"; }
CA_CERT=$(expand_dir "$CA_CERT")
CA_KEY="$CA_DIR/private/ca.key.pem"

# Check current CA cert expiry
EXPIRY=$(openssl x509 -in "$CA_CERT" -noout -enddate | cut -d= -f2)
EXP_TS=$(date -d "$EXPIRY" +%s)
NOW_TS=$(date +%s)
DAYS_LEFT=$(( (EXP_TS - NOW_TS) / 86400 ))

echo "Current CA cert expires on: $EXPIRY ($DAYS_LEFT days left)"

# Warn if too early
if [ $DAYS_LEFT -gt 365 ]; then
    echo "Warning: CA cert still valid for more than 1 year. Are you sure you want to renew now? (ctrl-c to abort)"
    sleep 5
fi

# Backup old CA cert
mv "$CA_CERT" "${CA_CERT}.old"

# Generate new CA cert with same key
openssl req -config "$CA_CONFIG" \
    -key "$CA_KEY" \
    -new -x509 -days 3650 -sha256 \
    -out "$CA_CERT"

chmod 644 "$CA_CERT"

echo "New CA certificate generated: $CA_CERT"
echo "Old CA certificate saved as: ${CA_CERT}.old"

# Fingerprints for verification
echo "SHA256 fingerprint of new CA:"
openssl x509 -in "$CA_CERT" -noout -fingerprint -sha256
echo
echo "SHA256 fingerprint of old CA:"
openssl x509 -in "${CA_CERT}.old" -noout -fingerprint -sha256

echo "CA renewal complete. Leaf cert issuance can continue as normal."
