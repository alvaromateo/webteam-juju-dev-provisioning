#!/usr/bin/env python3

"""
ingress_hosts_sync.py  (run on your HOST laptop)

Points your host's DNS at the in-VM HAProxy so you can open the app in a
browser. Reads the VM's external IP and the ingress hostnames from inside the
VM (populated by configure-ingress-forwarding.sh) and writes a managed block
into /etc/hosts. Works on Linux and macOS; only needs `multipass`.

Usage:
  sudo ./ingress_hosts_sync.py VM_NAME            # add/update entries
"""

import argparse
import os

from common_funcs import die, require, run


BEGIN_MARK = "# BEGIN ingress-local (managed)"
END_MARK = "# END ingress-local"
HOSTS_FILE = os.environ.get("HOSTS_FILE", "/etc/hosts")


def multipass(*args):
    """
    Run a multipass command and return its stdout (stripped).

    When the script runs under sudo (to write /etc/hosts), we must run
    multipass as the original invoking user. Multipass authorizes clients
    with a per-user certificate stored under that user's home; running as
    root uses a different, unregistered cert and the daemon reports VMs as
    "not found".
    """
    cmd = ["multipass", *args]
    sudo_user = os.environ.get("SUDO_USER")
    if os.geteuid() == 0 and sudo_user and sudo_user != "root":
        # -H resets HOME so multipass finds the invoking user's snap data/cert.
        cmd = ["sudo", "-H", "-u", sudo_user, *cmd]
    return run(cmd)


def strip_block(lines):
    """
    Return lines with any existing managed block removed.
    """
    out = []
    skip = False
    for line in lines:
        stripped = line.rstrip("\n")
        if stripped == BEGIN_MARK:
            skip = True
            continue
        if stripped == END_MARK:
            skip = False
            continue
        if not skip:
            out.append(line)
    return out


def read_hosts():
    with open(HOSTS_FILE, "r") as f:
        return f.readlines()


def write_hosts(lines):
    with open(HOSTS_FILE, "w") as f:
        f.writelines(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Sync in-VM ingress hostnames into /etc/hosts.",
    )
    parser.add_argument(
        "vm_name",
        help="Multipass VM name.",
    )
    args = parser.parse_args()

    require("multipass", "multipass is not installed or not on PATH")
    if not os.access(HOSTS_FILE, os.W_OK):
        die(f"cannot write {HOSTS_FILE} (re-run with sudo)")

    original = read_hosts()
    stripped = strip_block(original)

    return_code, _, _ = multipass("info", args.vm_name)
    if return_code != 0:
        die(f"VM '{args.vm_name}' not found (multipass info '{args.vm_name}' failed)")

    # VM external IP = source of the default route inside the VM (Multipass NIC).
    return_code, out, _ = multipass(
        "exec", args.vm_name, "--",
        "sh", "-c", "ip -4 route get 1.1.1.1 | awk '{print $7; exit}'",
    )
    vm_ip = out.strip()
    if return_code != 0 or not vm_ip:
        die(f"could not determine external IP of VM '{args.vm_name}'")

    # Get hostnames written by configure-ingress-forwarding.sh inside the VM.
    return_code, out, _ = multipass(
        "exec", args.vm_name, "--",
        "cat", "/etc/ingress-local/hostnames",
    )
    names = [line.strip() for line in out.splitlines() if line.strip()]
    if return_code != 0 or not names:
        die(
            f"no hostnames in '{args.vm_name}':/etc/ingress-local/hostnames "
            "— run configure-ingress-forwarding.sh in the VM first"
        )

    names_one_line = " ".join(names)
    new_lines = stripped + [
        f"{BEGIN_MARK}\n",
        f"{vm_ip} {names_one_line}\n",
        f"{END_MARK}\n",
    ]

    if new_lines == original:
        print(f"{HOSTS_FILE} already up to date ({vm_ip}).")
    else:
        write_hosts(new_lines)
        print(f"Updated {HOSTS_FILE}:  {vm_ip} -> {names_one_line}")

    first_name = names[0]
    print()
    print(f"Test it:  curl -k https://{first_name}")
    print(
        f"Then open https://{first_name} in your browser "
        "(self-signed cert warning is expected)."
    )


if __name__ == "__main__":
    main()
