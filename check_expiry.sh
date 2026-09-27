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

# Extract CA paths
CA_DIR=$(awk -F= '/^dir[ ]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' "$CA_CONFIG")
CA_CERT=$(awk -F= '/^certificate[ ]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' "$CA_CONFIG")
expand_dir() { echo "${1/\$dir/$CA_DIR}"; }
CA_CERT=$(expand_dir "$CA_CERT")

WARN_DAYS=${1:-30}  # default: warn if less than 30 days left

check_cert_expiry() {
    local file="$1"
    local name="$2"
    EXP=$(openssl x509 -in "$file" -noout -enddate | cut -d= -f2)
    EXP_TS=$(date -d "$EXP" +%s)
    NOW_TS=$(date +%s)
    DAYS_LEFT=$(( (EXP_TS - NOW_TS) / 86400 ))
    if [ $DAYS_LEFT -le $WARN_DAYS ]; then
        echo "WARNING: $name expires in $DAYS_LEFT days on $EXP"
    else
        echo "$name is valid for $DAYS_LEFT days (expires $EXP)"
    fi
}

# Check CA cert
check_cert_expiry "$CA_CERT" "CA cert"

# Check leaf certs under ./ssl if any
if [ -d "./ssl" ]; then
    for cert in $(find ./ssl -name "*.crt"); do
        check_cert_expiry "$cert" "Leaf cert: $cert"
    done
fi
