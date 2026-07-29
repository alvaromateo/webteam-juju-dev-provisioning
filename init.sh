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

# Check if LAUNCH_FILES_DIR environment variable is not defined
# and append it to .bashrc/.zshrc if missing (depending on the user SHELL)
if ! grep -q "export LAUNCH_FILES_DIR=" "$RC_FILE"; then
  echo "export LAUNCH_FILES_DIR=\"$REPO_DIR\"" >> "$RC_FILE"
  echo "Added LAUNCH_FILES_DIR to $RC_FILE"
fi

# Check if there's an alias for launch_lxd defined
# and append it to .bashrc/.zshrc if missing (depending on the user SHELL)
if ! grep -q "alias launch_lxd=" "$RC_FILE"; then
  echo "alias launch_lxd=\"$REPO_DIR/launch_instance_lxd.sh\"" >> "$RC_FILE"
  echo "Added launch_lxd alias to $RC_FILE"
fi

# Check if there's an alias for launch_vm defined
# and append it to .bashrc/.zshrc if missing (depending on the user SHELL)
if ! grep -q "alias launch_vm=" "$RC_FILE"; then
  echo "alias launch_vm=\"$REPO_DIR/launch_instance.sh\"" >> "$RC_FILE"
  echo "Added launch_vm alias to $RC_FILE"
fi

echo "Done."
echo "Source $RC_FILE or open a new terminal to use the new aliases."
echo "Copy juju_local.yaml.example to your project and save as juju_local.yaml."
echo "Then run one of the following:"
echo "    launch_lxd [NAME]"
echo "    launch_vm [NAME]"
