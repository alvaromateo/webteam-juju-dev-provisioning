#!/bin/bash

# Local Juju Environment Launcher (LXD)
# Launches an LXC container with Juju, MicroK8s, LXD, and optional services
#
# This is the lightweight alternative to launch_instance.sh (multipass/VM).
# It uses an LXD container instead of a full VM, consuming fewer resources
# at the cost of weaker isolation (shared host kernel).

set -e

# Default configuration
LAUNCH_FILES_DIR="${LAUNCH_FILES_DIR:-.}"
INSTANCE_NAME="${1:-juju-dev}"
INSTANCE_HOME="/home/ubuntu"
MOUNT_POINT="${INSTANCE_HOME}/project"
CLOUD_INIT_FILE="${LAUNCH_FILES_DIR}/cloud-init-juju-lxd.yaml"
IMAGE="${JUJU_LXD_IMAGE:-ubuntu:24.04}"

# Container Resources (can be overridden via environment variables)
CPUS="${JUJU_LXD_CPUS:-2}"
MEMORY="${JUJU_LXD_MEMORY:-3GB}"
DISK="${JUJU_LXD_DISK:-20GB}"
TIMEOUT="${JUJU_LXD_TIMEOUT:-3600}"

usage() {
    echo "Usage: $0 [INSTANCE_NAME]"
    echo ""
    echo "Launches an LXC container with a complete Juju development environment."
    echo ""
    echo "Arguments:"
    echo "  INSTANCE_NAME    Name for the LXC container (default: juju-dev)"
    echo ""
    echo "Environment Variables:"
    echo "  JUJU_LXD_IMAGE   Base image (default: ubuntu:24.04)"
    echo "  JUJU_LXD_CPUS    Number of CPUs (default: 2)"
    echo "  JUJU_LXD_MEMORY  Memory allocation (default: 3GB)"
    echo "  JUJU_LXD_DISK    Root disk size (default: 20GB)"
    echo "  JUJU_LXD_TIMEOUT Cloud-init timeout in seconds (default: 3600)"
    echo ""
    echo "Prerequisites:"
    echo "  - LXD installed and initialised (snap install lxd && lxd init --auto)"
    echo "  - cloud-init-juju-lxd.yaml file in the current directory"
    echo ""
    echo "Examples:"
    echo "  $0                        # Launch with default name 'juju-dev'"
    echo "  $0 myproject              # Launch with name 'myproject'"
    echo "  JUJU_LXD_CPUS=4 $0       # Launch with 4 CPUs"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

# Check prerequisites
if ! command -v lxc &> /dev/null; then
    echo "Error: lxc is not installed."
    echo "Install it with: snap install lxd && lxd init --auto"
    exit 1
fi

if [ ! -f "$CLOUD_INIT_FILE" ]; then
    echo "Error: Cloud-init file not found: $CLOUD_INIT_FILE"
    echo "Make sure you're running this script from the repository root."
    exit 1
fi

# Check if instance already exists
if lxc list --format csv -c n 2>/dev/null | grep -q "^${INSTANCE_NAME}$"; then
    echo "Container '$INSTANCE_NAME' already exists."
    echo "To delete it, run: lxc delete --force $INSTANCE_NAME"
    exit 1
fi

# Launch the LXC container with cloud-init
echo "Launching LXC container '$INSTANCE_NAME'..."
echo "  Image: $IMAGE"
echo "  CPUs: $CPUS"
echo "  Memory: $MEMORY"
echo "  Disk: $DISK"
echo "  Cloud-init timeout: ${TIMEOUT}s"
echo ""

# Detect the LXD managed bridge network
LXD_NETWORK=$(lxc network list --format csv 2>/dev/null | awk -F, '$2 == "bridge" && $3 == "YES" { print $1; exit }')
if [ -z "$LXD_NETWORK" ]; then
    echo "Error: No managed LXD bridge network found."
    echo "Run 'lxd init --auto' to create one, or create one with: lxc network create lxdbr0"
    exit 1
fi
echo "Using LXD network: $LXD_NETWORK"

lxc launch "$IMAGE" "$INSTANCE_NAME" \
    --network="$LXD_NETWORK" \
    --config=user.user-data="$(cat "$CLOUD_INIT_FILE")" \
    --config=limits.cpu="$CPUS" \
    --config=limits.memory="$MEMORY" \
    --config=boot.autostart=false \
    --config=security.nesting=true \
    --config=security.privileged=true \
    --config=linux.kernel_modules="ip_vs,ip_vs_rr,ip_vs_wrr,ip_vs_sh,ip_tables,ip6_tables,netlink_diag,nf_nat,overlay,br_netfilter" \
    --config=raw.lxc="lxc.apparmor.profile=unconfined
lxc.mount.auto=proc:rw sys:rw cgroup:rw
lxc.cgroup.devices.allow=a
lxc.cap.drop="

# Set root disk size
lxc config device override "$INSTANCE_NAME" root size="$DISK"

# /dev/kmsg is required by kubelet — pass it through from the host
lxc config device add "$INSTANCE_NAME" kmsg unix-char source=/dev/kmsg path=/dev/kmsg

# Add the necessary scripts
lxc file push ${LAUNCH_FILES_DIR}/setup-juju-env.sh "$INSTANCE_NAME/$INSTANCE_HOME"
lxc file push ${LAUNCH_FILES_DIR}/utils.sh "$INSTANCE_NAME/$INSTANCE_HOME"

# Mount the current directory into the container
lxc config device add "$INSTANCE_NAME" project disk source="$(pwd)" path="$MOUNT_POINT"

# Wait for container to be running
echo -n "Waiting for container to be ready"
while ! lxc list --format csv -c ns 2>/dev/null | grep -q "^${INSTANCE_NAME},RUNNING$"; do
    sleep 2
    echo -n "."
done
echo " Container is running and cloud-init is in progress!"
echo "Current directory mounted at $MOUNT_POINT."

# Follow cloud-init logs in real-time
echo "======================================"
echo "To follow the cloud-init output logs run the following command:"
echo "  lxc exec $INSTANCE_NAME -- tail -f /var/log/cloud-init-output.log"
echo "======================================"

# Wait for cloud-init to complete
echo "Waiting for cloud-init to complete..."
elapsed=0
while true; do
    status=$(lxc exec "$INSTANCE_NAME" -- cloud-init status 2>&1 || true)
    if [[ "$status" == *"done"* ]]; then
        echo "Cloud-init has completed successfully!"
        break
    elif [[ "$status" == *"error"* || "$status" == *"recoverable error"* ]]; then
        echo "WARNING: Cloud-init finished with errors."
        echo "Check logs with: lxc exec $INSTANCE_NAME -- cat /var/log/cloud-init-output.log"
        break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "WARNING: Cloud-init did not complete within ${TIMEOUT}s timeout."
        echo "Check logs with: lxc exec $INSTANCE_NAME -- cat /var/log/cloud-init-output.log"
        break
    fi
done

echo ""
echo "======================================"
echo "Container '$INSTANCE_NAME' is ready!"
echo ""
echo "Quick start commands:"
echo "  lxc exec $INSTANCE_NAME -- sudo --login --user ubuntu  # Shell into the container as ubuntu"
echo "  lxc exec $INSTANCE_NAME -- juju status                 # Check Juju status"
echo "  lxc exec $INSTANCE_NAME -- juju controllers            # List controllers"
echo ""
echo "Your project is mounted at: $MOUNT_POINT"
echo "Juju credentials are saved to: /home/ubuntu/.juju-credentials/"
echo "======================================"
