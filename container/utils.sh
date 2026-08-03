#!/bin/bash

# Local Juju Environment Utility Functions
# Source this file in your scripts: source ./utils.sh

# =============================================================================
# JUJU INFORMATION RETRIEVAL
# =============================================================================

# Returns: "10.203.10.58:17070"
get_juju_controller_address() {
    juju show-controller "$1" --format json 2>/dev/null | \
        python3 -c "import sys, json; print(json.load(sys.stdin)['$1']['details']['api-endpoints'][0])" 2>/dev/null
}

# Args: fully qualified model name "controller:model"
get_juju_model_uuid() {
    juju show-model "$1" --format json 2>/dev/null | \
        python3 -c "import sys, json; data = json.load(sys.stdin); print(data[list(data.keys())[0]]['model-uuid'])" 2>/dev/null
}

get_juju_controller_ca_cert() {
    juju show-controller "$1" --format json 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['$1']['details']['ca-cert'])" 2>/dev/null
}

# =============================================================================
# CREDENTIALS MANAGEMENT
# =============================================================================

# Returns: "username:password"
read_credentials_from_file() {
    [ ! -f "$1" ] && return 1
    local username password
    username=$(python3 -c "import yaml; print(yaml.safe_load(open('$1'))['username'])" 2>/dev/null)
    password=$(python3 -c "import yaml; print(yaml.safe_load(open('$1'))['password'])" 2>/dev/null)
    [ -n "$username" ] && [ -n "$password" ] && echo "$username:$password"
}

# =============================================================================
# VAULT FUNCTIONS
# =============================================================================

# Starts Vault in dev mode if not already running
start_vault_server() {
    export VAULT_ADDR="$1"
    export VAULT_TOKEN="$2"
    vault status &>/dev/null && return 0
    vault server -dev -dev-root-token-id="$2" -dev-listen-address="${1#http://}" &>/dev/null &
    sleep 2
}

# Ensures KV secrets engine is version 1 (Terraform provider compatibility)
ensure_vault_kv_v1() {
    local version=$(vault secrets list -format=json 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1/',{}).get('options',{}).get('version',''))" 2>/dev/null)
    [ "$version" = "2" ] && vault secrets disable "$1" &>/dev/null
    vault secrets enable -path="$1" -version=1 kv &>/dev/null || true
}

store_credentials_in_vault() {
    vault kv put "$1" username="$2" password="$3" >/dev/null
}

store_ca_cert_in_vault() {
    vault kv put "$1" ca_cert="$2" >/dev/null
}

# Returns: "role_id:secret_id"
setup_vault_approle() {
    vault auth enable approle &>/dev/null || true
    vault policy write "$1" - &>/dev/null <<EOF
path "$2" {
  capabilities = ["read", "list"]
}
path "auth/token/create" {
  capabilities = ["create", "update"]
}
EOF
    vault write "auth/approle/role/$1" token_policies="$1" token_ttl=1h token_max_ttl=4h &>/dev/null
    local role_id secret_id
    role_id=$(vault read -field=role_id "auth/approle/role/$1/role-id" 2>/dev/null)
    secret_id=$(vault write -field=secret_id -f "auth/approle/role/$1/secret-id" 2>/dev/null)
    echo "$role_id:$secret_id"
}

# =============================================================================
# TERRAFORM INTEGRATION
# =============================================================================

# Args: file, key, value, append("true"/"false")
write_tfvar() {
    if [ "$4" = "true" ]; then
        printf '%s = "%s"\n' "$2" "$3" >> "$1"
    else
        printf '%s = "%s"\n' "$2" "$3" > "$1"
    fi
}

# Args: controller, model_name, vault_key, credentials_dir, vault_base_path
setup_vault_for_model() {
    local creds_file="$4/$1-$2.yaml"
    local creds=$(read_credentials_from_file "$creds_file")
    [ -z "$creds" ] && { echo "Warning: No credentials found for model '$2' at $creds_file" >&2; return 1; }
    store_credentials_in_vault "$5/$3" "${creds%%:*}" "${creds##*:}"
    echo "✓ Stored credentials for $2 at $5/$3" >&2
}

# Main function to set up Vault for Terraform
# Usage:
#   setup_vault_for_terraform \
#     --controller myproject \
#     --model "myproject-k8s:k8s" \
#     --model "myproject-vm:vm" \
#     --tfvars-file ./terraform/juju.auto.tfvars
setup_vault_for_terraform() {
    local controller="" vault_address="http://127.0.0.1:8200" vault_token="dev-root-token"
    local credentials_dir="/home/ubuntu/.juju-credentials" vault_secret_path="secret/local/juju"
    local tfvars_file="" models=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --controller) controller="$2"; shift 2 ;;
            --vault-address) vault_address="$2"; shift 2 ;;
            --vault-token) vault_token="$2"; shift 2 ;;
            --credentials-dir) credentials_dir="$2"; shift 2 ;;
            --vault-secret-path) vault_secret_path="$2"; shift 2 ;;
            --tfvars-file) tfvars_file="$2"; shift 2 ;;
            --model) models+=("$2"); shift 2 ;;
            *) echo "Unknown parameter: $1" >&2; return 1 ;;
        esac
    done

    [ -z "$controller" ] && { echo "Error: --controller required" >&2; return 1; }

    echo "Setting up Vault for Terraform..." >&2
    echo "  Controller: $controller" >&2
    echo "  Vault: $vault_address" >&2
    echo "  Models: ${models[*]}" >&2

    start_vault_server "$vault_address" "$vault_token"
    ensure_vault_kv_v1 "${vault_secret_path%%/*}"

    local approle_creds=$(setup_vault_approle "terraform-juju" "${vault_secret_path}/*")
    local role_id="${approle_creds%%:*}" secret_id="${approle_creds##*:}"
    echo "✓ AppRole configured" >&2

    local ca_cert=$(get_juju_controller_ca_cert "$controller")
    [ -n "$ca_cert" ] && store_ca_cert_in_vault "${vault_secret_path}/ca_cert" "$ca_cert" && echo "✓ Stored CA certificate" >&2

    for model_spec in "${models[@]}"; do
        IFS=':' read -r model_name vault_key <<< "$model_spec"
        setup_vault_for_model "$controller" "$model_name" "$vault_key" "$credentials_dir" "$vault_secret_path"
    done

    if [ -n "$tfvars_file" ] && [ -f "$tfvars_file" ]; then
        echo "" >> "$tfvars_file"
        echo "# Vault AppRole credentials (auto-generated)" >> "$tfvars_file"
        write_tfvar "$tfvars_file" "vault_address" "$vault_address" "true"
        write_tfvar "$tfvars_file" "vault_approle_role_id" "$role_id" "true"
        write_tfvar "$tfvars_file" "vault_approle_secret_id" "$secret_id" "true"
        echo "✓ Vault variables appended to $tfvars_file" >&2
    fi

    echo "" >&2
    echo "Vault setup complete!" >&2

    export VAULT_ADDR="$vault_address"
    export VAULT_TOKEN="$vault_token"
    export TF_VAR_vault_approle_role_id="$role_id"
    export TF_VAR_vault_approle_secret_id="$secret_id"
}

# Export Juju controller/model info to Terraform variables file
# Usage:
#   export_terraform_vars \
#     --controller myproject \
#     --model "myproject-k8s:k8s" \
#     --model "myproject-vm:vm" \
#     --tfvars-file ./terraform/juju.auto.tfvars
export_terraform_vars() {
    local controller="" tfvars_file="" models=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --controller) controller="$2"; shift 2 ;;
            --tfvars-file) tfvars_file="$2"; shift 2 ;;
            --model) models+=("$2"); shift 2 ;;
            *) echo "Unknown parameter: $1" >&2; return 1 ;;
        esac
    done

    [ -z "$controller" ] && { echo "Error: --controller required" >&2; return 1; }
    [ -z "$tfvars_file" ] && { echo "Error: --tfvars-file required" >&2; return 1; }

    echo "Exporting Terraform variables..." >&2
    echo "  Controller: $controller" >&2
    echo "  Models: ${models[*]}" >&2

    local address=$(get_juju_controller_address "$controller")
    [ -z "$address" ] && { echo "Error: Could not get controller address" >&2; return 1; }

    echo "# Auto-generated by utils.sh - do not edit manually" > "$tfvars_file"
    write_tfvar "$tfvars_file" "juju_controller_addresses" "$address" "true"

    for model_spec in "${models[@]}"; do
        IFS=':' read -r model_name tfvar_prefix <<< "$model_spec"
        local uuid=$(get_juju_model_uuid "$controller:$model_name")
        [ -z "$uuid" ] && { echo "Error: Could not get UUID for '$model_name'" >&2; return 1; }
        write_tfvar "$tfvars_file" "${tfvar_prefix}_model" "$model_name" "true"
        write_tfvar "$tfvars_file" "${tfvar_prefix}_model_uuid" "$uuid" "true"
        echo "  Added ${tfvar_prefix}_model = $model_name" >&2
    done

    echo "✓ Terraform variables written to $tfvars_file" >&2
}

# =============================================================================
# DBAAS INTEGRATION
# =============================================================================

# Args: controller, model, application_endpoint, offer
integrate_application_with_offer() {
    juju switch "$1:$2" &>/dev/null || { echo "Error: Could not switch to model '$1:$2'" >&2; return 1; }
    if juju integrate "$3" "$4" 2>/dev/null; then
        echo "✓ Integrated $3 with $4" >&2
    else
        echo "  $3 integration already exists or failed" >&2
    fi
}

# Integrate applications with DBaaS PostgreSQL offer
# Usage:
#   integrate_dbaas_postgres \
#     --controller myproject \
#     --model myproject-k8s \
#     --integration "myapp:database" \
#     --integration "otherapp:database"
integrate_dbaas_postgres() {
    local controller="" model="" dbaas_controller="dbaas"
    local dbaas_offer="dbaas:admin/dbaas.dbaas-postgresql" integrations=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --controller) controller="$2"; shift 2 ;;
            --model) model="$2"; shift 2 ;;
            --dbaas-controller) dbaas_controller="$2"; shift 2 ;;
            --dbaas-offer) dbaas_offer="$2"; shift 2 ;;
            --integration) integrations+=("$2"); shift 2 ;;
            *) echo "Unknown parameter: $1" >&2; return 1 ;;
        esac
    done

    [ -z "$controller" ] && { echo "Error: --controller required" >&2; return 1; }
    [ -z "$model" ] && { echo "Error: --model required" >&2; return 1; }

    echo "Integrating applications with DBaaS PostgreSQL..." >&2
    echo "  Controller: $controller" >&2
    echo "  Model: $model" >&2
    echo "  DBaaS Offer: $dbaas_offer" >&2
    echo "  Integrations: ${integrations[*]}" >&2
    echo "" >&2

    juju show-controller "$dbaas_controller" --format json &>/dev/null || {
        echo "Error: $dbaas_controller controller not found" >&2
        return 1
    }

    local success_count=0
    for integration in "${integrations[@]}"; do
        integrate_application_with_offer "$controller" "$model" "$integration" "$dbaas_offer"
        ((success_count++))
    done

    echo "" >&2
    echo "✓ DBaaS integrations complete! ($success_count processed)" >&2
}
