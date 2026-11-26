#!/usr/bin/env python3
"""Remote certificate and SSH host-key security gates (Task 12).

Static checks pin the fail-closed contracts without connecting to a guest or
changing a certificate store. The live Paramiko policy check uses only a
throwaway known_hosts file in a temporary directory.
"""
import os
import re
import sys
import tempfile

try:
    import paramiko
except ImportError:  # Static fail-closed gates remain mandatory everywhere.
    paramiko = None


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REMOTE = os.path.join(ROOT, "tools", "remote")
FAILURES = []


def check(label, ok):
    print(("  PASS " if ok else "  FAIL ") + label)
    if not ok:
        FAILURES.append(label)


def source(name):
    with open(os.path.join(REMOTE, name), encoding="utf-8-sig") as handle:
        return handle.read()


def mandatory_string_param(src, name):
    pattern = (
        r"\[Parameter\(Mandatory\s*=\s*\$true\)\]\s*"
        r"(?:\[ValidateNotNullOrEmpty\(\)\]\s*)?"
        r"\[string\]\$" + re.escape(name) + r"\b"
    )
    return re.search(pattern, src) is not None


def check_certificate_gate():
    src = source("Restore-DriverCertTrust.ps1")
    check("certificate thumbprint is a required parameter",
          mandatory_string_param(src, "ExpectedThumbprint"))
    check("certificate subject is a required parameter",
          mandatory_string_param(src, "ExpectedSubject"))

    guards = [
        "certificate signature must be Valid",
        "certificate thumbprint must match",
        "certificate subject must match",
    ]
    needles = [
        "$sig.Status -ne 'Valid'",
        "$cert.Thumbprint -ne $ExpectedThumbprint",
        "$cert.Subject -ne $ExpectedSubject",
    ]
    import_at = src.find("Import-Certificate")
    check("certificate import exists", import_at >= 0)
    for label, needle in zip(guards, needles):
        at = src.find(needle)
        check(label, at >= 0)
        check(label + " before any import", 0 <= at < import_at)


def check_openssh_gate(name, invocation_count):
    src = source(name)
    check(name + ": known_hosts is a required parameter",
          mandatory_string_param(src, "KnownHostsFile"))
    check(name + ": known_hosts existence is checked",
          "Test-Path $KnownHostsFile" in src)
    check(name + ": automatic host-key acceptance is absent",
          "StrictHostKeyChecking=no" not in src)
    check(name + ": every SSH/SCP call requires strict host keys",
          src.count("StrictHostKeyChecking=yes") == invocation_count)
    controlled_options = re.findall(
        r"UserKnownHostsFile[^\r\n]*\$KnownHostsFile", src)
    check(name + ": every SSH/SCP call selects the controlled known_hosts",
          len(controlled_options) == invocation_count)


def check_paramiko_gate(name):
    src = source(name)
    check(name + ": automatic host-key acceptance is absent",
          "AutoAddPolicy" not in src)
    check(name + ": controlled known_hosts environment input is required",
          'os.environ.get("VM_KNOWN_HOSTS")' in src)
    check(name + ": controlled known_hosts file is loaded",
          ".load_host_keys(known_hosts)" in src)
    check(name + ": controlled known_hosts existence is checked",
          "os.path.isfile(known_hosts)" in src)
    check(name + ": unknown host keys are rejected",
          "paramiko.RejectPolicy()" in src)
    load_at = src.find(".load_host_keys(")
    reject_at = src.find("paramiko.RejectPolicy()")
    connect_at = src.find("ssh.connect(")
    check(name + ": host keys and reject policy precede connect",
          0 <= load_at < reject_at < connect_at)


def check_live_reject_policy():
    """Exercise the real reject policy without opening a socket."""
    if paramiko is None:
        print("  SKIP live RejectPolicy check (Paramiko is not installed)")
        return
    with tempfile.TemporaryDirectory(prefix="auradsp-known-hosts-") as tmp:
        known_hosts = os.path.join(tmp, "known_hosts")
        key = paramiko.RSAKey.generate(2048)
        with open(known_hosts, "w", encoding="ascii") as handle:
            handle.write("vm.test %s %s\n" % (key.get_name(), key.get_base64()))

        client = paramiko.SSHClient()
        try:
            client.load_host_keys(known_hosts)
            client.set_missing_host_key_policy(paramiko.RejectPolicy())
            loaded = client._host_keys.lookup("vm.test")
            check("temporary known_hosts supplies the pinned host key",
                  loaded is not None
                  and loaded.get(key.get_name()) == key)
            # RejectPolicy logs through the client's transport; logging is
            # irrelevant here and no transport exists because no socket opens.
            client._log = lambda *args: None
            try:
                client._policy.missing_host_key(client, "unknown.test", key)
            except paramiko.SSHException:
                check("RejectPolicy rejects an unknown host key", True)
            else:
                check("RejectPolicy rejects an unknown host key", False)
        finally:
            client.close()


def main():
    check_certificate_gate()
    check_openssh_gate("Invoke-GuestScript.ps1", 2)
    check_openssh_gate("Send-ToGuest.ps1", 3)
    check_paramiko_gate("vm_exec.py")
    check_paramiko_gate("sync_to_vm.py")
    check_live_reject_policy()

    if FAILURES:
        print("smoke_remote_security: %d FAIL" % len(FAILURES))
        return 1
    print("smoke_remote_security: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
