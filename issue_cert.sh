#!/bin/bash
set -e

# =========================
# Load environment
# =========================
if [ ! -f .env ]; then
    echo "Missing .env file. Run init_ca.sh first."
    exit 1
fi

set -a
source .env
set +a

if [ -z "$CA_CONFIG" ]; then
    echo "CA_CONFIG not set in .env"
    exit 1
fi

# Base dir for issued certs = current directory
BASE_DIR="$(pwd)"
CERTS_BASE="$BASE_DIR/ssl"

# =========================
# ARG PARSING
# =========================
MODE="$1"
shift

REVOKE_OLD=false
if [ "$MODE" == "renew" ] && [ "$1" == "--revoke-old" ]; then
    REVOKE_OLD=true
    shift
fi

if [ "$MODE" != "create" ] && [ "$MODE" != "renew" ]; then
    echo "First argument must be 'create' or 'renew'"
    exit 1
fi

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 $MODE [--revoke-old] <domain> <hostname> [ip]"
    exit 1
fi

DOMAIN="$1"
HOST="$2"
IP="${3:-}"

HOST_DIR="$CERTS_BASE/$DOMAIN/$HOST"

CNF="$HOST_DIR/$HOST.cnf"
KEY="$HOST_DIR/$HOST.key"
CSR="$HOST_DIR/$HOST.csr"
CRT="$HOST_DIR/$HOST.crt"
INFO_FILE="$HOST_DIR/.cert_info"

mkdir -p "$HOST_DIR"

# =========================
# Read CA paths from config
# =========================
get_conf_val() {
    local key="$1"
    awk -F= -v k="$key" '
        $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
        }
    ' "$CA_CONFIG"
}

CA_DIR=$(get_conf_val "dir")
CA_CERT=$(get_conf_val "certificate")
CA_DB=$(get_conf_val "database")

expand_dir() {
    echo "${1/\$dir/$CA_DIR}"
}

CA_CERT=$(expand_dir "$CA_CERT")
CA_DB=$(expand_dir "$CA_DB")

# =========================
# Rotate helper
# =========================
rotate() {
    local file="$1"
    if [ -f "$file" ]; then
        local n=1
        while [ -f "$file.$n" ]; do n=$((n+1)); done
        mv "$file" "$file.$n"
    fi
}

# =========================
# Change detection
# =========================
REGENERATE_CERT=true
if [ -f "$INFO_FILE" ]; then
    OLD_IP=$(grep '^IP=' "$INFO_FILE" | cut -d= -f2)
    OLD_CN=$(grep '^CN=' "$INFO_FILE" | cut -d= -f2)
    if [ "$OLD_IP" == "$IP" ] && [ "$OLD_CN" == "${HOST}.${DOMAIN}" ]; then
        echo "IP and CN unchanged; skipping rotation and CSR generation."
        REGENERATE_CERT=false
    fi
fi

# =========================
# Generate host OpenSSL config
# =========================
cat > "$CNF" <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = $DN_C
ST = $DN_ST
L  = $DN_L
O  = $DN_O
OU = $DN_OU
CN = ${HOST}.${DOMAIN}

[ req_ext ]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ alt_names ]
DNS.1 = ${HOST}
DNS.2 = ${HOST}.${DOMAIN}
EOF

if [ -n "$IP" ]; then
    echo "IP.1  = ${IP}" >> "$CNF"
fi

# =========================
# Generate or reuse key
# =========================
if [ ! -f "$KEY" ]; then
    echo "Generating new private key..."
    openssl genrsa -out "$KEY" 2048
    chmod 600 "$KEY"
else
    echo "Reusing existing key: $KEY"
fi

# =========================
# Revoke / Rotate / Reissue if needed
# =========================
if $REGENERATE_CERT; then

    if [ "$MODE" == "renew" ] && $REVOKE_OLD; then
        CURRENT_CERT_LINE=$(grep "/CN=${HOST}.${DOMAIN}" "$CA_DB" | grep -v "^R" | tail -n1)
        if [ -n "$CURRENT_CERT_LINE" ]; then
            SERIAL=$(echo "$CURRENT_CERT_LINE" | awk '{print $3}')
            echo "Revoking current valid certificate for $HOST.$DOMAIN (serial $SERIAL)"
            CERT_FILE=$(grep "$SERIAL" "$CA_DB" | awk '{print $5}')
            if [ -z "$CERT_FILE" ] || [ ! -f "$CERT_FILE" ]; then
                echo "Warning: certificate file for serial $SERIAL not found, using $CRT"
                CERT_FILE="$CRT"
            fi
            openssl ca -config "$CA_CONFIG" -revoke "$CERT_FILE"
        fi
    fi

    rotate "$CSR"
    rotate "$CRT"

    echo "Generating CSR..."
    openssl req -new -key "$KEY" -out "$CSR" -config "$CNF"

    echo "Signing certificate..."
    openssl ca -config "$CA_CONFIG" -extensions v3_server -in "$CSR" -out "$CRT" -batch

    echo "IP=$IP" > "$INFO_FILE"
    echo "CN=${HOST}.${DOMAIN}" >> "$INFO_FILE"

else
    echo "No changes detected; reusing existing CSR and certificate."
fi

# =========================
# Verify
# =========================
openssl verify -CAfile "$CA_CERT" "$CRT"

echo "Certificate issued successfully:"
echo "  $CRT"
