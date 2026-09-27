#!/bin/bash
# generate_ca_bundle.sh
# Usage: ./generate_ca_bundle.sh [output-file]
# Combines all current valid CA certificates into a single bundle file.

set -e

# Load CA info
if [ ! -f ".env" ]; then
    echo "Error: .env file not found. Run init_ca.sh first."
    exit 1
fi
source .env

# Use DN_O + DN_OU as default "company name" for bundle if no filename provided
OUTPUT_FILE="$1"
if [ -z "$OUTPUT_FILE" ]; then
    # Combine DN_O and DN_OU, sanitize for filesystem (remove spaces/special chars)
    SAFE_NAME=$(echo "${DN_O}${DN_OU}" | tr -cd '[:alnum:]_-')
    OUTPUT_FILE="${SAFE_NAME}.ca_bundle"
fi

# Collect all valid CA certs
CA_DIR=$(dirname "$CA_CONFIG")   # directory where CA config lives

if [ ! -d "$CA_DIR/certs" ]; then
    echo "Error: CA certs directory not found at $CA_DIR/certs"
    exit 1
fi

# Temporary array to hold valid certs
VALID_CERTS=()

# Current date in seconds since epoch
NOW=$(date +%s)

for cert in "$CA_DIR/certs/"*.pem "$CA_DIR/certs/"*.old; do
    [ -f "$cert" ] || continue
    # Get expiration date in seconds
    EXPIRY=$(date -d "$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)" +%s)
    if [ "$EXPIRY" -gt "$NOW" ]; then
        VALID_CERTS+=("$cert")
    fi
done


if [ ${#VALID_CERTS[@]} -eq 0 ]; then
    echo "No valid CA certificates found."
    exit 1
fi

# Combine into bundle
> "$OUTPUT_FILE"
for cert in "${VALID_CERTS[@]}"; do
    cat "$cert" >> "$OUTPUT_FILE"
    echo >> "$OUTPUT_FILE"  # separate certs with newline
done

echo "CA bundle generated: $OUTPUT_FILE"
