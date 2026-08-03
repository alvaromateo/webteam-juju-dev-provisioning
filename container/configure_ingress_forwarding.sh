#!/usr/bin/env bash

# configure_ingress_forwarding.sh  (run INSIDE the VM)
#
# Reads the discovered addresses from `terraform output` and installs a static
# nftables DNAT rule so the VM's external IP forwards HTTP(S) to the HAProxy
# unit (which runs in an LXD container and is not reachable from the host).
#
# Usage:
#   sudo ./configure_ingress_forwarding.sh
#
# Run this from the Terraform directory provisioned, after `terraform apply`.

set -euo pipefail

CONF_DIR="/etc/ingress-local"
NFT_FILE="$CONF_DIR/ingress.nft"
HOSTS_FILE="$CONF_DIR/hostnames"
CA_CERT_FILE="$CONF_DIR/ca-cert"

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

# Verify we're in an applied Terraform directory
ls | grep -q '\.tf$' || die "run the script from a Terraform directory"
[ -f terraform.tfstate ] || die "no Terraform state found; run 'terraform apply' first"

# Read discovered values from Terraform outputs
out() {
  terraform output -raw "$1" 2>/dev/null \
    || die "terraform output '$1' not found; your Terraform config must output it"
}
out_json() {
  terraform output -json "$1" 2>/dev/null \
    || die "terraform output '$1' not found; your Terraform config must output it"
}

# Obtain values from terraform configured ingress
VM_IP="$(out vm_ip)"
HAPROXY_IP="$(out haproxy_ip)"
PORTS="$(out ports)"
HOSTNAMES="$(out_json hostnames | tr -d '[]"' | tr ',' '\n')"
# Obtain value from terraform for the CA certificate configured at the ingress 
CA_CERT="$(out ca_certificate)"

# replace commas with comma + space
PORTSET="$(echo "$PORTS" | sed 's/,/, /g')"

# Write config + rendered nft ruleset
mkdir -p "$CONF_DIR"
printf '%s\n' "$HOSTNAMES" > "$HOSTS_FILE"

# prerouting forwards traffic from outside the VM to HAProxy
# postrouting makes sure traffic can travel back from HAProxy to outside the VM
cat > "$NFT_FILE" <<EOF
#!/usr/sbin/nft -f
# Managed by local-ps7/bin/configure-ingress-forwarding.sh — do not edit.
table ip ingress_local
delete table ip ingress_local
table ip ingress_local {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr $VM_IP tcp dport { $PORTSET } dnat to $HAPROXY_IP
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr $HAPROXY_IP tcp dport { $PORTSET } masquerade
  }
}
EOF

# Apply the nft ruleset 
nft -f "$NFT_FILE"

# Write the CA certificate to be trusted for ingress
printf '%s\n' "$CA_CERT" > "$CA_CERT_FILE"

echo "Configured forwarding: $VM_IP:{$PORTS} -> $HAPROXY_IP"
echo "Hostnames: $(echo "$HOSTNAMES" | tr '\n' ' ')"
echo ""
echo "Next, on your host laptop run:"
echo "    sudo ingress_hosts_sync <vm-name>"
echo "    container_ca_trust <vm-name>"
