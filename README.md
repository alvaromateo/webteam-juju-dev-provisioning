# Local Juju Environment Provisioning

Provision local Juju development environments on either a **Multipass VM** or an **LXD container**. Replicate production/staging Juju environments locally for testing Terraform plans and charm deployments.

## What gets installed

- **Juju 3.6** - Charm orchestration
- **MicroK8s** - Local Kubernetes cluster with registry, ingress, and storage
- **LXD** - Container/VM substrate for machine charms
- **Charmcraft & Rockcraft** - Charm and rock development tools
- **Terraform** - Infrastructure as code
- **Vault** (optional) - Secrets management
- **DBaaS** (optional) - PostgreSQL with cross-model offers

## Quick start

### 1. Install

Git clone this repository and optionally witch to the branch/tag of the version you want to use.
Then enter the directory and run:

```bash
chmod +x init.sh
./init.sh
```

This will add 2 alias commands to your .bashrc/.zshrc (source those files or open a new terminal
to be able to run them).
- launch_vm
- launch_lxd

### 2. Configure your environment

Copy the example config into your project and edit it according to your needs:

```bash
cp juju_local.yaml.example juju_local.yaml
```

```yaml
schema_version: "1.0"

juju:
  version: "3.6/candidate"

controllers:
  - name: "myproject"

models:
  - name: "myproject-k8s"
    controller: "myproject"
    cloud: "microk8s"

  - name: "myproject-vm"
    controller: "myproject"
    cloud: "localhost"

services:
  - vault
  - dbaas
```

### 3. Launch

```bash
# LXD
launch_lxd myproject

# VM
launch_vm myproject
```

### 4. Access

```bash
# LXD
lxc exec myproject -- sudo --login --user ubuntu

# VM
multipass shell myproject
```

## Resource Customisation

### LXD container

```bash
JUJU_LXD_CPUS=4 JUJU_LXD_MEMORY=4GB ./launch_instance_lxd.sh myproject
```

| Variable | Default | Description |
|----------|---------|-------------|
| `JUJU_LXD_IMAGE`   | `ubuntu:24.04` | Base image |
| `JUJU_LXD_CPUS`    | `2`    | Number of CPUs |
| `JUJU_LXD_MEMORY`  | `3GB`  | Memory allocation |
| `JUJU_LXD_DISK`    | `20GB` | Root disk size |
| `JUJU_LXD_TIMEOUT` | `3600` | Cloud-init timeout (seconds) |

### Multipass VM

```bash
JUJU_VM_CPUS=8 JUJU_VM_MEMORY=8G ./launch_instance.sh myproject
```

| Variable | Default | Description |
|----------|---------|-------------|
| `JUJU_VM_CPUS`    | `6`    | Number of CPUs |
| `JUJU_VM_MEMORY`  | `6G`   | Memory allocation |
| `JUJU_VM_DISK`    | `50G`  | Disk size |
| `JUJU_VM_TIMEOUT` | `3600` | Launch timeout (seconds) |

## Utility Functions and Scripts

### host

These scripts are meant to run directly in the host.

Only macOS and Linux systems are supported.

### container

These scripts are meant to run inside the VM or LXC instances.

Source `utils.sh` inside the instance for Terraform and Vault integration:

```bash
source /home/ubuntu/utils.sh

# Export Juju connection info to a tfvars file
export_terraform_vars \
  --controller myproject \
  --model "myproject-k8s:k8s" \
  --model "myproject-vm:vm" \
  --tfvars-file ./terraform/juju.auto.tfvars

# Integrate an app with the PostgreSQL cross-model offer
integrate_dbaas_postgres \
  --controller myproject \
  --model myproject-k8s \
  --integration "myapp:database"
```

## Common Commands

### LXD

```bash
lxc list                                                  # List containers
lxc exec myproject -- sudo --login --user ubuntu          # Shell in
lxc exec myproject -- juju status                         # Juju status
lxc exec myproject -- tail -f /var/log/cloud-init-output.log  # Cloud-init logs
lxc stop myproject                                        # Stop
lxc start myproject                                       # Start
lxc delete --force myproject                              # Delete
lxc config device add myproject <unique-id> disk source=<host-folder> path=<instance-folder>  # Bind other folders
```

### Multipass

```bash
multipass list                                            # List instances
multipass shell myproject                                 # Shell in
multipass exec myproject -- juju status                   # Juju status
multipass exec myproject -- tail -f /var/log/cloud-init-output.log  # Cloud-init logs
multipass stop myproject                                  # Stop
multipass start myproject                                 # Start
multipass delete myproject && multipass purge             # Delete
multipass mount <host-folder> myproject:<instance-folder>  # Bind other folders
```

## Credentials

After provisioning, credentials are saved inside the instance:

| Path | Description |
|------|-------------|
| `/home/ubuntu/.juju-credentials/` | User credentials (YAML files) |
| `/home/ubuntu/.juju-tokens/` | Registration tokens |
| `/home/ubuntu/.kube/config` | Kubernetes config |

Each model gets a user with the same name and password as the model name.

## Versioning

This repository uses semantic versioning. To use a specific version, switch to the corresponding branch/tag
in the cloned repository.

Check the [releases page](https://github.com/canonical/webteam-juju-dev-provisioning/releases) for available versions.

If you need different versions for different projects you can clone the repository multiple times or
use [Git Worktrees](https://git-scm.com/docs/git-worktree). Then you can invoke the `launch` commands passing
the following environment variable pointing to the directory with the version you need:

```bash
JUJU_DEV_DIR=<path-to-dir> launch_vm
JUJU_DEV_DIR=<path-to-dir> launch_lxd
```

## Troubleshooting

```bash
# Check cloud-init status
lxc exec myproject -- cloud-init status          # LXD
multipass exec myproject -- cloud-init status     # VM

# View full cloud-init logs
lxc exec myproject -- cat /var/log/cloud-init-output.log
multipass exec myproject -- cat /var/log/cloud-init-output.log

# MicroK8s not ready
lxc exec myproject -- microk8s status --wait-ready

# Juju logs
lxc exec myproject -- juju debug-log
```
