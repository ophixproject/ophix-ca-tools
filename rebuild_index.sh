#!/bin/bash
# Usage: ./rebuild_index.sh <certs_directory> <output_index_file>

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <certs_directory> <output_index_file>"
    exit 1
fi

CERT_DIR="$1"
INDEX_FILE="$2"

> "$INDEX_FILE"  # empty the index file

for cert in "$CERT_DIR"/*.crt; do
    [ -f "$cert" ] || continue

    # Get expiration date in ASN1 UTC format (YYMMDDHHMMSSZ)
    EXP=$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)
    EXP_ASN1=$(date -u -d "$EXP" +"%y%m%d%H%M%SZ")

    # Get serial number in uppercase hex
    SERIAL=$(openssl x509 -in "$cert" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')

    # Get subject DN
    SUBJECT=$(openssl x509 -in "$cert" -noout -subject | sed 's/subject= //')

    # Write to index.txt
    echo "V   $EXP_ASN1   $SERIAL   unknown   $SUBJECT" >> "$INDEX_FILE"
done

echo "Index rebuilt at $INDEX_FILE from certificates in $CERT_DIR"

