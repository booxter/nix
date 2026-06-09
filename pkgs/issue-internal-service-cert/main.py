#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

import yaml


DEFAULT_CA_HOST = "prox-pkivm"
DEFAULT_PROVISIONER = "bootstrap@home.arpa"
DEFAULT_STEP_PATH = "/var/lib/step-ca"
DEFAULT_PROVISIONER_PASSWORD_FILE = "/var/lib/step-ca/provisioner-password.txt"
LOCAL_CA_ENV = "ISSUE_CERT_LOCAL_CA"
PROXMOX_API_SERVICE = "proxmox-api"


def find_repo_root():
    env_root = os.environ.get("ISSUE_INTERNAL_SERVICE_CERT_REPO_ROOT")
    if env_root:
        candidate = pathlib.Path(env_root).expanduser().resolve()
        if (candidate / "flake.nix").exists():
            return candidate
        raise SystemExit(
            f"ISSUE_INTERNAL_SERVICE_CERT_REPO_ROOT does not point to a flake checkout: {candidate}"
        )

    for start in [
        pathlib.Path.cwd().resolve(),
        pathlib.Path(__file__).resolve().parent,
    ]:
        for candidate in [start, *start.parents]:
            if (candidate / "flake.nix").exists():
                return candidate

    proc = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=pathlib.Path.cwd(),
        text=True,
        capture_output=True,
    )
    if proc.returncode == 0:
        candidate = pathlib.Path(proc.stdout.strip()).resolve()
        if (candidate / "flake.nix").exists():
            return candidate

    raise SystemExit(
        "could not determine repo root; run from the checkout or set ISSUE_INTERNAL_SERVICE_CERT_REPO_ROOT"
    )


REPO_ROOT = find_repo_root()


def run(cmd, *, cwd=REPO_ROOT, input_text=None):
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        input=input_text,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return proc.stdout


def run_optional(cmd, *, cwd=REPO_ROOT):
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def nix_segment(name):
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        return name
    return json.dumps(name)


def nix_attr_path(*segments):
    return ".#" + ".".join(nix_segment(segment) for segment in segments)


def nix_eval_json(*segments):
    raw = run(["nix", "eval", "--json", nix_attr_path(*segments)])
    return json.loads(raw)


def nix_eval_raw_optional(*segments):
    raw = run_optional(["nix", "eval", "--raw", nix_attr_path(*segments)])
    if raw is None:
        return None
    return raw.strip()


def canonical_host_name(host):
    expr = f"""
let
  f = builtins.getFlake {json.dumps(str(REPO_ROOT))};
  inventory = import {json.dumps(str(REPO_ROOT / "lib/inventory.nix"))} {{
    lib = f.inputs.nixpkgs.lib;
  }};
  name = {json.dumps(host)};
  specName = inventory.nixosConfigNameToSpecName name;
in
  if builtins.hasAttr specName inventory.nixosHostSpecsByName then
    inventory.toNixosConfigName (builtins.getAttr specName inventory.nixosHostSpecsByName)
  else
    name
"""
    return run(["nix", "eval", "--impure", "--raw", "--expr", expr]).strip()


def secret_name_for_host(host):
    match = re.fullmatch(r"prox-(.+)vm", host)
    if match:
        return match.group(1)
    return host


def secret_path_for_host(host):
    return REPO_ROOT / "secrets" / f"{secret_name_for_host(host)}.yaml"


def set_nested(mapping, dotted_path, value):
    cursor = mapping
    for key in dotted_path[:-1]:
        next_value = cursor.get(key)
        if not isinstance(next_value, dict):
            next_value = {}
            cursor[key] = next_value
        cursor = next_value
    cursor[dotted_path[-1]] = value


def unique_strings(values):
    result = []
    seen = set()
    for value in values:
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def host_config_root(host):
    for root in ("nixosConfigurations", "darwinConfigurations"):
        if nix_eval_raw_optional(root, host, "config", "host", "dnsName") is not None:
            return root
    raise SystemExit(
        f"host {host} not found in nixosConfigurations or darwinConfigurations"
    )


def service_names_for_host(host):
    root = host_config_root(host)
    service_map = (
        nix_eval_json(root, host, "config", "host", "internalHttps", "services") or {}
    )
    services = sorted(
        name for name, service in service_map.items() if service.get("enable")
    )
    if proxmox_api_service_enabled(root, host):
        services.append(PROXMOX_API_SERVICE)
    return services


def service_config(host, service):
    root = host_config_root(host)
    if service == PROXMOX_API_SERVICE:
        return proxmox_api_service_config(root, host)
    return nix_eval_json(
        root, host, "config", "host", "internalHttps", "services", service
    )


def proxmox_api_service_enabled(root, host):
    enabled = nix_eval_raw_optional(
        root,
        host,
        "config",
        "host",
        "proxmox",
        "apiCertificate",
        "enable",
    )
    return enabled == "true"


def proxmox_api_service_config(root, host):
    cfg = nix_eval_json(root, host, "config", "host", "proxmox", "apiCertificate")
    sans = unique_strings([cfg["serverName"], *cfg.get("serverAliases", [])])
    return cfg | {"sans": sans}


def client_names_for_host(host):
    root = host_config_root(host)
    client_map = (
        nix_eval_json(root, host, "config", "host", "externalService", "mtlsClients")
        or {}
    )
    return sorted(name for name, client in client_map.items() if client.get("enable"))


def client_config(host, client):
    root = host_config_root(host)
    return nix_eval_json(
        root, host, "config", "host", "externalService", "mtlsClients", client
    )


def issue_remote_cert(*, ca_host, common_name, sans):
    san_args = " ".join(f"--san {shlex.quote(san)}" for san in sans)
    script = f"""
set -euo pipefail
tmpdir="$(sudo -u step-ca mktemp -d)"
cleanup() {{
  sudo -u step-ca rm -rf "$tmpdir"
}}
trap cleanup EXIT
sudo -u step-ca env HOME={shlex.quote(DEFAULT_STEP_PATH)} STEPPATH={shlex.quote(DEFAULT_STEP_PATH)} \\
  step ca certificate {shlex.quote(common_name)} "$tmpdir/server.crt" "$tmpdir/server.key" \\
  {san_args} \\
  --provisioner {shlex.quote(DEFAULT_PROVISIONER)} \\
  --provisioner-password-file {shlex.quote(DEFAULT_PROVISIONER_PASSWORD_FILE)} \\
  >/dev/null
printf '%s\\n' '__CERT__'
sudo -u step-ca cat "$tmpdir/server.crt"
printf '%s\\n' '__KEY__'
sudo -u step-ca cat "$tmpdir/server.key"
"""
    if os.environ.get(LOCAL_CA_ENV) == "1":
        output = run(["bash", "-lc", script], cwd=None)
    else:
        output = run(["ssh", ca_host, "bash", "-s"], cwd=None, input_text=script)
    cert_marker = "__CERT__\n"
    key_marker = "\n__KEY__\n"
    if not output.startswith(cert_marker) or key_marker not in output:
        raise SystemExit("unexpected certificate output from CA host")
    cert_body = output[len(cert_marker) :]
    cert_text, key_text = cert_body.split(key_marker, 1)
    return cert_text.strip() + "\n", key_text.strip() + "\n"


def update_secret_file(host, service, service_cfg, cert_text, key_text):
    secret_path = secret_path_for_host(host)
    if not secret_path.exists():
        raise SystemExit(f"secret file not found: {secret_path}")

    run([str(REPO_ROOT / "scripts" / "sops-update.sh"), host])
    decrypted = run(["sops", "--decrypt", str(secret_path)])
    data = yaml.safe_load(decrypted) or {}

    prefix = service_cfg["secretPrefix"].split("/")
    set_nested(data, prefix + ["server_crt"], cert_text.rstrip("\n"))
    set_nested(data, prefix + ["server_key"], key_text.rstrip("\n"))

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(data, handle, sort_keys=True)
        handle.write("\n")
        payload_path = handle.name

    try:
        encrypted = run(
            [
                "sops",
                "--encrypt",
                "--filename-override",
                str(secret_path),
                "--input-type",
                "json",
                "--output-type",
                "yaml",
                payload_path,
            ]
        )
        secret_path.write_text(encrypted)
    finally:
        pathlib.Path(payload_path).unlink(missing_ok=True)


def issue_service(host, service, *, ca_host):
    service_cfg = service_config(host, service)
    if not service_cfg.get("enable"):
        raise SystemExit(
            f"internal HTTPS service {service} on host {host} is not enabled"
        )

    sans = unique_strings(
        service_cfg.get("sans")
        or [service, service_cfg["serverName"], *service_cfg.get("serverAliases", [])]
    )
    common_name = service_cfg["serverName"]
    cert_text, key_text = issue_remote_cert(
        ca_host=ca_host, common_name=common_name, sans=sans
    )
    update_secret_file(host, service, service_cfg, cert_text, key_text)
    print(
        json.dumps(
            {
                "host": host,
                "service": service,
                "secret_prefix": service_cfg["secretPrefix"],
                "port": service_cfg["port"],
                "server_name": service_cfg["serverName"],
                "sans": sans,
            }
        )
    )


def update_client_secret_file(host, client_cfg, cert_text, key_text):
    secret_path = secret_path_for_host(host)
    if not secret_path.exists():
        raise SystemExit(f"secret file not found: {secret_path}")

    run([str(REPO_ROOT / "scripts" / "sops-update.sh"), host])
    decrypted = run(["sops", "--decrypt", str(secret_path)])
    data = yaml.safe_load(decrypted) or {}

    prefix = client_cfg["secretPrefix"].split("/")
    set_nested(data, prefix + ["client_crt"], cert_text.rstrip("\n"))
    set_nested(data, prefix + ["client_key"], key_text.rstrip("\n"))

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(data, handle, sort_keys=True)
        handle.write("\n")
        payload_path = handle.name

    try:
        encrypted = run(
            [
                "sops",
                "--encrypt",
                "--filename-override",
                str(secret_path),
                "--input-type",
                "json",
                "--output-type",
                "yaml",
                payload_path,
            ]
        )
        secret_path.write_text(encrypted)
    finally:
        pathlib.Path(payload_path).unlink(missing_ok=True)


def issue_client(host, client, *, ca_host):
    client_cfg = client_config(host, client)
    if not client_cfg.get("enable"):
        raise SystemExit(
            f"internal HTTPS client {client} on host {host} is not enabled"
        )

    sans = unique_strings([client_cfg["commonName"], *client_cfg.get("sans", [])])
    common_name = client_cfg["commonName"]
    cert_text, key_text = issue_remote_cert(
        ca_host=ca_host, common_name=common_name, sans=sans
    )
    update_client_secret_file(host, client_cfg, cert_text, key_text)
    print(
        json.dumps(
            {
                "host": host,
                "client": client,
                "secret_prefix": client_cfg["secretPrefix"],
                "common_name": common_name,
                "sans": sans,
            }
        )
    )


def main():
    parser = argparse.ArgumentParser(
        prog="issue-internal-service-cert",
        description="Issue internal PKI certs for internal HTTPS services and store them in host sops secrets.",
    )
    parser.add_argument(
        "--host", required=True, help="Inventory host name, e.g. srvarr"
    )
    parser.add_argument("--service", help="Internal HTTPS service name, e.g. glance")
    parser.add_argument(
        "--client", help="Internal HTTPS mTLS client identity name, e.g. vikunja"
    )
    parser.add_argument(
        "--ca-host", default=DEFAULT_CA_HOST, help="SSH host running step-ca"
    )
    args = parser.parse_args()

    if args.service and args.client:
        raise SystemExit("--service and --client are mutually exclusive")

    host = canonical_host_name(args.host)
    ca_host = canonical_host_name(args.ca_host)

    if args.client:
        clients = [args.client]
        if not clients:
            raise SystemExit(
                f"host {host} has no configured internal HTTPS mTLS clients"
            )
        for client in clients:
            issue_client(host, client, ca_host=ca_host)
        return

    services = [args.service] if args.service else service_names_for_host(host)
    if not services:
        raise SystemExit(f"host {host} has no configured internal HTTPS services")

    for service in services:
        issue_service(host, service, ca_host=ca_host)


if __name__ == "__main__":
    main()
