#!/bin/bash

# Local Juju Environment Launcher
# Launches a multipass VM with Juju, MicroK8s, LXD, and optional services

set -e

# Default configuration
LAUNCH_FILES_DIR="${LAUNCH_FILES_DIR:-.}"
INSTANCE_NAME="${1:-juju-dev}"
INSTANCE_HOME="/home/ubuntu"
MOUNT_POINT="${INSTANCE_HOME}/project"
CLOUD_INIT_FILE="${LAUNCH_FILES_DIR}/cloud-init-juju.yaml"

# VM Resources (can be overridden via environment variables)
CPUS="${JUJU_VM_CPUS:-6}"
MEMORY="${JUJU_VM_MEMORY:-6G}"
DISK="${JUJU_VM_DISK:-50G}"
TIMEOUT="${JUJU_VM_TIMEOUT:-3600}"

usage() {
    echo "Usage: $0 [INSTANCE_NAME]"
    echo ""
    echo "Launches a multipass VM with a complete Juju development environment."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE_NAME    Name for the multipass instance (default: juju-dev)"
    echo ""
    echo "Environment Variables:"
    echo "  JUJU_VM_CPUS     Number of CPUs (default: 6)"
    echo "  JUJU_VM_MEMORY   Memory allocation (default: 6G)"
    echo "  JUJU_VM_DISK     Disk size (default: 50G)"
    echo "  JUJU_VM_TIMEOUT  Launch timeout in seconds (default: 3600)"
    echo ""
    echo "Prerequisites:"
    echo "  - multipass installed (https://multipass.run/)"
    echo "  - juju_local.yaml file in the current directory (optional)"
    echo ""
    echo "Examples:"
    echo "  $0                        # Launch with default name 'juju-dev'"
    echo "  $0 myproject              # Launch with name 'myproject'"
    echo "  JUJU_VM_CPUS=8 $0         # Launch with 8 CPUs"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

# Check prerequisites
if ! command -v multipass &> /dev/null; then
    echo "Error: multipass is not installed."
    echo "Install it from: https://multipass.run/"
    exit 1
fi

if [ ! -f "$CLOUD_INIT_FILE" ]; then
    echo "Error: Cloud-init file not found: $CLOUD_INIT_FILE"
    echo "Make sure you're running this script from the repository root."
    exit 1
fi

# Check if instance already exists
if multipass list 2>/dev/null | grep -q "^$INSTANCE_NAME "; then
    echo "Instance '$INSTANCE_NAME' already exists."
    echo "To delete it, run: multipass delete $INSTANCE_NAME && multipass purge"
    exit 1
fi

# Launch the multipass instance with cloud-init
echo "Launching $INSTANCE_NAME instance..."
echo "  CPUs: $CPUS"
echo "  Memory: $MEMORY"
echo "  Disk: $DISK"
echo "  Timeout: ${TIMEOUT}s"
echo ""

# Redirect multipass output to suppress the spinner
multipass launch --name "$INSTANCE_NAME" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK" --timeout "$TIMEOUT" --cloud-init "$CLOUD_INIT_FILE" > /tmp/multipass-launch.log 2>&1 &

# Wait for instance to be running
echo -n "Waiting for instance to be ready"
while ! multipass list 2>/dev/null | grep -q "$INSTANCE_NAME.*Running"; do
    sleep 2
    echo -n "."
done
echo " Instance is running and cloud-init is in progress!"

# Add the necessary scripts
multipass transfer ${LAUNCH_FILES_DIR}/setup-juju-env.sh "$INSTANCE_NAME:$INSTANCE_HOME"
multipass transfer ${LAUNCH_FILES_DIR}/utils.sh "$INSTANCE_NAME:$INSTANCE_HOME"

# Mount the current directory immediately once VM is running
echo "Mounting current directory to $MOUNT_POINT..."
multipass mount . "$INSTANCE_NAME:$MOUNT_POINT"
echo "Mounted current directory."

# Follow cloud-init logs in real-time
echo "======================================"
echo "To follow the cloud-init output logs run the following command:"
echo "  multipass exec $INSTANCE_NAME -- tail -f /var/log/cloud-init-output.log"
echo "======================================"

# Check cloud-init status
echo "Waiting for cloud-init to complete..."
while true; do
    status=$(multipass exec "$INSTANCE_NAME" -- cloud-init status --wait || true)
    if [[ "$status" == *"done"* ]]; then
        echo "Cloud-init has completed successfully!"
        break
    fi
done

echo ""
echo "======================================"
echo "Instance '$INSTANCE_NAME' is ready!"
echo ""
echo "Quick start commands:"
echo "  multipass shell $INSTANCE_NAME                    # SSH into the VM"
echo "  multipass exec $INSTANCE_NAME -- juju status      # Check Juju status"
echo "  multipass exec $INSTANCE_NAME -- juju controllers # List controllers"
echo ""
echo "Your project is mounted at: $MOUNT_POINT"
echo "Juju credentials are saved to: /home/ubuntu/.juju-credentials/"
echo "======================================"
