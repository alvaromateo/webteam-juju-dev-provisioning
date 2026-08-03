#!/bin/bash
set -e

chmod +x ./*.sh

# Absolute path to this repository (where the launch scripts and files live)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check which SHELL does the user use
case "$(basename "${SHELL:-}")" in
  zsh)
    RC_FILE="$HOME/.zshrc"
    ;;
  bash)
    RC_FILE="$HOME/.bashrc"
    ;;
  *)
    # Fall back to bash if the shell can't be determined
    RC_FILE="$HOME/.bashrc"
    echo "Warning: could not detect your shell from \$SHELL, defaulting to $RC_FILE"
    ;;
esac

# Make sure the rc file exists before we append to it
touch "$RC_FILE"

# Check if JUJU_DEV_DIR environment variable is not defined
# and append it to .bashrc/.zshrc if missing (depending on the user SHELL)
if ! grep -q "export JUJU_DEV_DIR=" "$RC_FILE"; then
  echo "# webteam-juju-dev-provisioning" >> "$RC_FILE"
  echo "export JUJU_DEV_DIR=\"$REPO_DIR\"" >> "$RC_FILE"
  echo "Added JUJU_DEV_DIR to $RC_FILE"
fi

# Aliases to add: alias name -> target script (relative to REPO_DIR)
# Append each to .bashrc/.zshrc if missing (depending on the user SHELL)
declare -A ALIASES=(
  [launch_lxd]="launch_instance_lxd.sh"
  [launch_vm]="launch_instance.sh"
  [ingress_hosts_sync]="ingress_hosts_sync.py"
  [container_ca_trust]="ca_trust.py"
)

for alias_name in "${!ALIASES[@]}"; do
  if ! grep -q "alias ${alias_name}=" "$RC_FILE"; then
    echo "alias ${alias_name}=\"$REPO_DIR/host/${ALIASES[$alias_name]}\"" >> "$RC_FILE"
    echo "Added ${alias_name} alias to $RC_FILE"
  fi
done

# Needed to avoid this issue:
# https://askubuntu.com/questions/22037/aliases-not-available-when-using-sudo
if ! grep -q "alias sudo='sudo '" "$RC_FILE"; then
  echo "alias sudo='sudo '" >> "$RC_FILE"
fi

echo "Done."
echo "Source $RC_FILE or open a new terminal to use the new aliases."
echo "Copy juju_local.yaml.example to your project and save as juju_local.yaml."
echo "Then run one of the following:"
echo "    launch_lxd [NAME]"
echo "    launch_vm [NAME]"
