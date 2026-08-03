#!/bin/bash

# Shared Juju environment setup script.
# Called by both cloud-init-juju.yaml (VM) and cloud-init-juju-lxd.yaml (container)
# after MicroK8s and base packages are ready.
#
# This script handles:
#   1. Terraform installation
#   2. Juju bootstrap, model creation, and user provisioning
#   3. Optional service deployment (vault, dbaas)
#
# Expected to run as root with /home/ubuntu/project mounted.

set -e

JUJU_ENV_FILE="/home/ubuntu/project/juju_local.yaml"

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------
install_terraform() {
  echo ""
  echo "===== Installing Terraform ====="
  wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
  apt update && apt install -y terraform
  echo "Terraform installed: $(terraform version | head -1)"
}

# ---------------------------------------------------------------------------
# Juju user helper
# ---------------------------------------------------------------------------
add_juju_user_with_password() {
  local username=$1
  local password=$2
  local controller=$3
  local model=$4

  echo "Creating user $username for model $model"

  # Add user and capture registration token
  local output
  output=$(sudo -u ubuntu juju add-user "$username" -c "$controller" 2>&1)

  if [ $? -eq 0 ]; then
    echo "User $username added successfully"

    # Set the user's password (--no-prompt reads single line from stdin)
    echo "Setting password for user $username"
    echo "$password" | sudo -u ubuntu juju change-user-password "$username" --no-prompt -c "$controller"

    # Grant admin access to the specific model (admin needed for creating offers)
    echo "Granting $username admin access to model $model"
    sudo -u ubuntu juju grant "$username" admin "$model" -c "$controller"

    # Save credentials to file for later use (Vault/Terraform)
    sudo -u ubuntu mkdir -p /home/ubuntu/.juju-credentials
    local creds_file="/home/ubuntu/.juju-credentials/${controller}-${username}.yaml"
    printf 'username: %s\npassword: %s\ncontroller: %s\nmodel: %s\n' \
      "$username" "$password" "$controller" "$model" | sudo -u ubuntu tee "$creds_file" > /dev/null
    chmod 600 "$creds_file"
    echo "Credentials saved to $creds_file"

    # Extract and save registration token for later use
    local token
    token=$(echo "$output" | grep "juju register" | sed 's/.*juju register //')
    if [ -n "$token" ]; then
      echo "Registration token saved to /home/ubuntu/.juju-tokens/${controller}-${username}.token"
      sudo -u ubuntu mkdir -p /home/ubuntu/.juju-tokens
      echo "$token" | sudo -u ubuntu tee "/home/ubuntu/.juju-tokens/${controller}-${username}.token" > /dev/null
      echo "To register this user from another machine, use: juju register $token"
    fi
  else
    echo "Failed to add user $username: $output"
  fi
}

# ---------------------------------------------------------------------------
# Juju environment bootstrap
# ---------------------------------------------------------------------------
setup_juju_environment() {
  echo ""
  echo "===== Setting up juju environment ====="

  # Ensure microk8s is ready before getting its config
  echo "Waiting for microk8s to be ready..."
  microk8s status --wait-ready

  # Prepare kubeconfig for juju (needed for add-k8s command)
  echo "Creating kubeconfig for juju..."
  sudo -u ubuntu mkdir -p /home/ubuntu/.kube
  microk8s config | sudo -u ubuntu tee /home/ubuntu/.kube/config > /dev/null
  sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

  if [ -f "$JUJU_ENV_FILE" ]; then
    echo "$JUJU_ENV_FILE exists, setting up juju environment from configuration."

    # Bootstrap all controllers on localhost (LXD) first
    for name in $(python3 -c 'import yaml; [print(c["name"]) for c in yaml.safe_load(open("'"$JUJU_ENV_FILE"'")).get("controllers", [])]'); do
      echo "Bootstrapping controller $name on localhost (LXD)"
      sudo -u ubuntu juju bootstrap localhost "$name"
    done

    # Add mk8s cloud to client first
    echo "Adding mk8s cloud to juju client..."
    sudo -u ubuntu juju add-k8s mk8s --client

    # Then add mk8s cloud to each controller
    for name in $(python3 -c 'import yaml; [print(c["name"]) for c in yaml.safe_load(open("'"$JUJU_ENV_FILE"'")).get("controllers", [])]'); do
      echo "Adding mk8s cloud to controller $name"
      sudo -u ubuntu juju add-k8s mk8s --controller "$name" 2>&1 || echo "Warning: mk8s may already exist on controller $name"
    done

    # Create models with cloud specification and users
    python3 -c 'import yaml; [print(m["name"] + " " + m["controller"] + " " + m.get("cloud", "localhost")) for m in yaml.safe_load(open("'"$JUJU_ENV_FILE"'")).get("models", [])]' | while read -r model_name controller_name cloud_name; do
      # Map 'microk8s' cloud name to the shared mk8s cloud
      if [ "$cloud_name" = "microk8s" ]; then
        actual_cloud="mk8s"
      else
        actual_cloud="$cloud_name"
      fi

      echo "Creating model $model_name on cloud $actual_cloud in controller $controller_name"
      sudo -u ubuntu juju add-model "$model_name" "$actual_cloud" -c "$controller_name"

      # Create user for model (username and password = model name)
      add_juju_user_with_password "$model_name" "$model_name" "$controller_name" "$model_name"
    done

    echo "Juju environment provisioning complete!"
    deploy_services
  else
    echo "$JUJU_ENV_FILE does not exist. Creating default controllers."

    # Bootstrap two separate controllers for simple default setup
    echo "Bootstrapping default microk8s controller..."
    sudo -u ubuntu juju bootstrap microk8s microk8s

    echo "Bootstrapping default lxd controller..."
    sudo -u ubuntu juju bootstrap localhost lxd

    echo "Default controllers created: 'microk8s' and 'lxd'"
    echo "Use 'juju switch microk8s' or 'juju switch lxd' to select a controller"
  fi
}

# ---------------------------------------------------------------------------
# Optional services
# ---------------------------------------------------------------------------
deploy_services() {
  echo "Checking for services to deploy..."

  local services_line
  services_line=$(python3 -c 'import yaml; services = yaml.safe_load(open("'"$JUJU_ENV_FILE"'")).get("services", []); print(" ".join(services) if services else "")')

  if [ -z "$services_line" ]; then
    echo "No services to deploy"
    return
  fi

  for service in $services_line; do
    echo "Deploying service: $service"

    case "$service" in
      vault)
        echo "Setting up Vault service..."
        # HashiCorp apt repo already configured by install_terraform
        apt update && apt install -y vault
        echo "Vault service deployed."
        ;;

      dbaas)
        echo "Setting up DBaaS service..."
        sudo -u ubuntu juju bootstrap localhost dbaas
        sudo -u ubuntu juju add-model dbaas localhost -c dbaas
        sudo -u ubuntu juju deploy postgresql -n 1 -m dbaas:dbaas --channel 14/stable

        echo "Waiting for PostgreSQL to become active..."
        sudo -u ubuntu juju wait-for application postgresql -m dbaas:dbaas --timeout=10m

        echo "Creating PostgreSQL offer..."
        sudo -u ubuntu juju offer -c dbaas postgresql:database dbaas-postgresql

        echo "DBaaS service deployed. PostgreSQL offer: dbaas:admin/dbaas.dbaas-postgresql"
        ;;

      *)
        echo "Unknown service: $service. Skipping..."
        ;;
    esac
  done

  echo "All services deployed successfully!"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_terraform
setup_juju_environment
