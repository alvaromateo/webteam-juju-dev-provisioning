#!/usr/bin/env python3

"""Trust (or untrust) a self-signed CA used by the environment ingress.

The `self-signed-certificates` Juju charm acts as a private CA and issues the
certificate that HAProxy serves. Browsers reject that certificate because the
issuing CA is not in any trust store, which in turn breaks SSO/OAuth logins that
refuse to run over untrusted TLS.

This script extracts the CA from the charm and installs it into the local trust
stores so that any browser trusts the ephemeral environment, then lets you clean
it up again when the environment is destroyed.

It is intentionally a standalone helper (no Terraform wiring) so it fits an
ephemeral "apply / test / destroy" loop:

    # inside the VM
    terraform apply
    configure_ingress_forwarding
    # in the host
    ingress_hosts_sync
    ca_trust.py install                 # trust this env's CA
    ...test in any browser...
    ca_trust.py remove                  # clean up

Trust stores by platform:
- Firefox family browsers always use NSS (cert9.db)
- Chromium family brosers use NSS on Linux and Keychain on macOS
- Webkit (Safari) uses macOS Keychain

No `sudo` is required. On macOS, setting Keychain trust may raise a one-time
Touch ID / password GUI prompt (inherent to the login keychain); Firefox-family
support there is best-effort and is skipped with a warning if `certutil` is not
installed (`brew install nss`).
"""


from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

from collections.abc import Callable
from common_funcs import die, run, warn, system_has
from pathlib import Path


CA_CERT_FILE = "/etc/ingress-local/ca-cert"
CERT_START = "-----BEGIN CERTIFICATE-----"
CERT_END = "-----END CERTIFICATE-----"

# Base directories searched (recursively) for Firefox-family `cert9.db` NSS DBs.
LINUX_NSS_BASES = ("~/.pki", "~/.mozilla", "~/.config", "~/snap", "~/.var/app")
MACOS_NSS_BASES = ("~/Library/Application Support",)

IS_MACOS = sys.platform == "darwin"

# Where we cache the CA fingerprint/subject so we can precisely delete the
# macOS Keychain entry even after the charm (and env) are gone.
STATE_DIR = Path(
    os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))
) / "local-juju-envs" / "ca_trust"
STATE_COMMON_NAME = "common_name"


# -------------------------------------------------------------------
# CA extraction
# -------------------------------------------------------------------

def fetch_ca_pem(vm_name: str) -> str:
    """
    Get the CA certificate written by configure-ingress-forwarding.sh
    inside the VM.
    """
    return_code, pem, _ = run([
        "multipass", "exec", vm_name, "--",
        "cat", CA_CERT_FILE
    ])
    if return_code != 0 or not pem:
        die(f"could not retrieve certificate from multipass's VM - {vm_name}")
    return normalize_pem(pem)


def normalize_pem(pem: str) -> str:
    """
    Trim to a single CERTIFICATE block and ensure a trailing newline.
    """
    start = pem.find(CERT_START)
    stop = pem.find(CERT_END)
    if start == -1 or stop == -1:
        die("malformed CA certificate (no PEM boundaries).")
    block = pem[start : stop + len(CERT_END)]
    return block.strip() + "\n"


def cert_subject_common_name(pem: str) -> str | None:
    """
    Extract the subject's common name via openssl.
    This is used to be able to search for the cert in Keychain (macOS)
    for the certificate removal.
    """
    if system_has("openssl"):
        return_code, out, _ = run(
            [
                "openssl", "x509",
                "-noout",
                "-subject",
                "-nameopt", "RFC2253"
            ],
            input=pem,
        )
        # out example:
        # subject=CN = self-signed-certificates-operator, x500UniqueIdentifier = 89883a4d-e3b6-4793-937f-2a983799ea61
        if return_code != 0:
            return None
        for field in out.replace("subject=", "").split(","):
            field = field.strip()
            if field.upper().startswith("CN"):
                common_name = field.split("=")[1]
                return common_name.strip()
    return None


# -------------------------------------------------------------------
# NSS (certutil) store handling
#
# Firefox family in ALL platforms
# Chromium family only on Linux (macOS handles it through Keychain)
# -------------------------------------------------------------------

def discover_nss_dbs() -> list[Path]:
    """
    Return directories containing an NSS `cert9.db`.
    It searches recursively (rglob) inside each of the base directories specified.
    """
    bases = MACOS_NSS_BASES if IS_MACOS else LINUX_NSS_BASES
    dirs: set[Path] = set()
    for base in bases:
        root = Path(base).expanduser()
        if not root.is_dir():
            continue
        try:
            for db in root.rglob("cert9.db"):
                dirs.add(db.parent)
        except (PermissionError, OSError):
            continue
    return sorted(dirs)


def create_shared_nss_db() -> None:
    """
    Ensure the shared NSS DB (~/.pki/nssdb) exists.
    Chromium doesn't create it until some certificate is added.
    If it doesn't exist, create it.
    """
    if IS_MACOS:
        return

    nss_db = Path.home() / ".pki" / "nssdb"
    if (nss_db / "cert9.db").exists():
        return

    # create DB (cert9.db) at ~/.pki/nssdb
    nss_db.mkdir(parents=True, exist_ok=True)
    return_code, _, error_msg = run([
        "certutil",
        "-d", f"sql:{nss_db}",      # path where to create the DB
        "-N",                       # create new
        "--empty-password"          # use an empty password for the new DB
    ])

    if return_code != 0:
        warn(f"could not initialize {nss_db}: {error_msg.strip()}")


def nss_add(db: Path, cert_nickname: str, ca_file: str) -> bool:
    # Delete first the certificate for idempotency.
    nss_remove(db, cert_nickname, warn_if_error=False)
    return_code, _, error_msg = run([
        "certutil",
        "-d", f"sql:{db}",          # path to the DB
        "-A",                       # add certificate
        "-t", "C,,",                # specify trust attributes for the cert (C,, = SSL Trusted CA)
        "-n", cert_nickname,        # nickname given to the new cert
        "-i", ca_file               # input cert file
    ])
    if return_code != 0:
        warn(f"certutil failed for {db}: {error_msg.strip()}")
        return False
    return True


def nss_remove(db: Path, cert_nickname: str, warn_if_error: bool = True) -> bool:
    return_code, _, error_msg = run([
        "certutil",
        "-d", f"sql:{db}",          # path of the DB to modify
        "-D",                       # delete certificate
        "-n", cert_nickname,        # certificate to perfom the action on
    ])
    if return_code != 0 and warn_if_error:
        warn(f"certutil remove failed for {db}: {error_msg.strip()}")
        return False
    return True


def nss_has(db: Path, cert_nickname: str) -> bool:
    return_code, _, _ = run([
        "certutil",
        "-d", f"sql:{db}",          # path to the DB
        "-L",
        "-n", cert_nickname,
    ])
    return return_code == 0


# -------------------------------------------------------------------
# macOS Keychain handling
#
# Uses `security` CLI tool:
# https://www.unix.com/man-page/osx/1/security/
# -------------------------------------------------------------------

def login_keychain() -> str:
    return_code, out, _ = run(["security", "login-keychain"])
    if return_code == 0:
        path = out.strip().strip('"')
        if path:
            return path
    # default keychain
    return str(Path.home() / "Library" / "Keychains" / "login.keychain-db")


def keychain_add(ca_pem: str) -> bool:
    keychain = login_keychain()
    print(
        "macOS: adding CA to the login keychain "
        "(you may get a Touch ID / password prompt)..."
    )
    return_code, _, error_msg = run([
        "security",
        "add-trusted-cert",
        "-r", "trustRoot",          # trusts a self-signed certificate
        "-p", "ssl",                # cert policy (what is it used for)
        "-k", keychain,             # add cert to this keychain
        ca_pem,                     # cert file
    ])
    if return_code != 0:
        warn(f"security add-trusted-cert failed: {error_msg.strip()}")
        return False
    return True


def keychain_remove(common_name: str) -> bool:
    keychain = login_keychain()
    return_code, _, _ = run([
        "security",
        "delete-certificate",
        "-c", common_name,          # specify cert to delete by common name
        keychain                    # remove cert from this keychain
    ])
    if return_code == 0:
        return True
    return False


def keychain_has(common_name: str) -> bool:
    keychain = login_keychain()
    return_code, _, _ = run([
        "security",
        "find-certificate",
        "-c", common_name,          # match certificate on common name
        keychain                    # search in this keychain
    ])
    return return_code == 0


# -------------------------------------------------------------------
# Cache CA identity so `remove` works after the env is gone
# -------------------------------------------------------------------

def state_path(cert_nickname: str) -> Path:
    """
    Retrieve the saved local VM certificate by nickname.
    Nickname is the terminology given to each certificate's 'easy name'
    to avoid long legal or technical names.
    """
    return STATE_DIR / f"{cert_nickname}.json"


def save_state(cert_nickname: str, common_name: str | None) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_path(cert_nickname).write_text(json.dumps({
        STATE_COMMON_NAME: common_name,
    }))


def load_state(cert_nickname: str) -> str | None:
    try:
        data = json.loads(state_path(cert_nickname).read_text())
        return data.get(STATE_COMMON_NAME)
    except (OSError, json.JSONDecodeError):
        return None


def clear_state(cert_nickname: str) -> None:
    try:
        state_path(cert_nickname).unlink()
    except OSError:
        pass


# -------------------------------------------------------------------
# Update store and keychain utils
# -------------------------------------------------------------------

def update_nss_db(
    update_func: Callable[[Path, str, str | None], bool],
    cert_nickname: str,
    ca_file: str | None,
) -> bool:
    db_updated = False
    if system_has("certutil"):
        # Initialise the shared DB store first so browsers can pick it up.
        create_shared_nss_db()
        for db in discover_nss_dbs():
            db_updated = update_func(db, cert_nickname, ca_file)
    else:
        warn("'certutil' not found")

    return db_updated


def nss_db_add(db: Path, cert_nickname: str, ca_file: str | None) -> bool:
    if not ca_file:
        warn("  failed adding cert (NSS): missing PEM certificate")
        return False
    if nss_add(db, cert_nickname, ca_file):
        print(f"  trusted (NSS): {db}")
        return True
    return False


def nss_db_remove(db: Path, cert_nickname: str, _: str | None) -> bool:
    if nss_has(db, cert_nickname):
        if nss_remove(db, cert_nickname):
            print(f"  removed (NSS): {db}")
            return True
    return False


def macos_keychain_add(ca_file: str) -> bool:
    updated = keychain_add(ca_file)
    if updated:
        print("  trusted (macOS login Keychain)")
        return True
    return False


def macos_keychain_remove(common_name: str) -> bool:
    updated = keychain_remove(common_name)
    if updated:
        print("  removed (macOS login Keychain)")
        return True
    return False


# -------------------------------------------------------------------
# Install/Remove CA cert functions
# -------------------------------------------------------------------

def get_cert_nickname(vm_name) -> str:
    return f"{vm_name}_cacert"


def install_cert(args) -> int:
    pem = fetch_ca_pem(args.vm_name)
    cert_nickname = get_cert_nickname(args.vm_name)

    with tempfile.NamedTemporaryFile(
        "w", suffix=".pem", delete=False
    ) as tmp:
        tmp.write(pem)
        ca_file = tmp.name

    nss_updated = False
    keychain_updated = False
    try:
        # Firefox family on all platforms + Chromium on Linux
        nss_updated = update_nss_db(nss_db_add, cert_nickname, ca_file)
        # Safari + Chromium family on macOS via Keychain.
        if IS_MACOS:
            keychain_updated = macos_keychain_add(ca_file)
    finally:
        try:
            os.unlink(ca_file)
        except OSError:
            pass

    if nss_updated or keychain_updated:
        save_state(cert_nickname, cert_subject_common_name(pem))
        print(
            f"\nDone: CA trusted in store(s) as '{cert_nickname}'.\n"
            "Restart any open browsers to pick up the new trust."
        )
    else:
        die("no trust stores were updated.")
        
    return 0


def remove_cert(args) -> int:
    cert_nickname = get_cert_nickname(args.vm_name)
    common_name = load_state(cert_nickname)

    keychain_updated = False
    nss_updated = update_nss_db(nss_db_remove, cert_nickname, None)
    if IS_MACOS:
        if common_name is None:
            warn("no cached CA identity found; cannot remove the macOS Keychain "
                 "entry precisely. It may have already been removed.")
        else:
            keychain_updated = macos_keychain_remove(common_name)

    if nss_updated or keychain_updated:
        clear_state(cert_nickname)
        print(f"\nDone: removed CA trust from store(s).")
    else:
        print("Nothing to remove (already clean).")

    return 0


# -------------------------------------------------------------------
# Script entrypoint
# -------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Trust/untrust the local VM self-signed ingress CA in browsers.",
    )
    parser.add_argument(
        "vm_name",
        help="Multipass VM name.",
    )
    parser.add_argument(
        "-d", "--delete",
        help="Remove the local VM self-signed CA certificates from the browsers store.",
        action="store_true",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.delete:
        return remove_cert(args)
    return install_cert(args)


if __name__ == "__main__":
    sys.exit(main())
