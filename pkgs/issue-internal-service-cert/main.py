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


DEFAULT_CA_HOST = "pki"
DEFAULT_PROVISIONER = "bootstrap@home.arpa"
DEFAULT_STEP_PATH = "/var/lib/step-ca"
DEFAULT_PROVISIONER_PASSWORD_FILE = "/var/lib/step-ca/provisioner-password.txt"
LOCAL_CA_ENV = "ISSUE_CERT_LOCAL_CA"
PROXMOX_API_SERVICE = "proxmox-api"
DEFAULT_UNIFI_COMMON_NAME = "unifi.home.arpa"


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


def secret_path_for_host(host):
    return REPO_ROOT / "secrets" / f"{host}.yaml"


_KNOWN_INVENTORY_HOSTS = None


def known_inventory_hosts():
    global _KNOWN_INVENTORY_HOSTS
    if _KNOWN_INVENTORY_HOSTS is None:
        expr = f"""
let
  f = builtins.getFlake {json.dumps(str(REPO_ROOT))};
  inventory = import {json.dumps(str(REPO_ROOT / "lib/inventory.nix"))} {{
    lib = f.inputs.nixpkgs.lib;
  }};
in
  builtins.attrNames inventory.nixosHostSpecsByName
  ++ builtins.attrNames inventory.darwinHosts
"""
        _KNOWN_INVENTORY_HOSTS = set(
            json.loads(
                run(
                    [
                        "nix",
                        "--extra-experimental-features",
                        "nix-command flakes",
                        "eval",
                        "--impure",
                        "--json",
                        "--expr",
                        expr,
                    ]
                )
            )
        )
    return _KNOWN_INVENTORY_HOSTS


def validate_inventory_host(host):
    if host not in known_inventory_hosts():
        raise SystemExit(f"Unknown host: {host}")


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


def unifi_common_name():
    return os.environ.get(
        "ISSUE_INTERNAL_SERVICE_CERT_UNIFI_COMMON_NAME",
        DEFAULT_UNIFI_COMMON_NAME,
    )


def unifi_default_sans(common_name):
    raw = os.environ.get("ISSUE_INTERNAL_SERVICE_CERT_UNIFI_SANS_JSON")
    if not raw:
        return [common_name]

    try:
        values = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SystemExit(
            f"ISSUE_INTERNAL_SERVICE_CERT_UNIFI_SANS_JSON is not valid JSON: {error}"
        ) from error

    if not isinstance(values, list) or not all(
        isinstance(value, str) for value in values
    ):
        raise SystemExit(
            "ISSUE_INTERNAL_SERVICE_CERT_UNIFI_SANS_JSON must be a JSON string list"
        )
    return values


def validate_basename(value):
    basename = pathlib.PurePath(value)
    if basename.name != value or value in ("", ".", ".."):
        raise SystemExit(f"invalid output basename: {value}")
    return value


def write_output(path, text, mode, *, force):
    if path.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing file: {path}")

    tmp_path = path.with_name(f".{path.name}.tmp")
    try:
        with tmp_path.open("w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    finally:
        tmp_path.unlink(missing_ok=True)


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


def issue_remote_cert(*, ca_host, common_name, sans, bundle=False):
    san_args = " ".join(f"--san {shlex.quote(san)}" for san in sans)
    bundle_arg = "--bundle" if bundle else ""
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
  {bundle_arg} \\
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


def issue_unifi(args):
    common_name = args.common_name or unifi_common_name()
    sans = unique_strings(
        [common_name, *unifi_default_sans(common_name), *(args.san or [])]
    )
    gateway_ip = os.environ.get("ISSUE_INTERNAL_SERVICE_CERT_UNIFI_GATEWAY_IP")
    if args.include_gateway_ip and gateway_ip:
        sans = unique_strings([*sans, gateway_ip])

    basename = validate_basename(args.basename or common_name)
    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

    cert_path = output_dir / f"{basename}.crt"
    key_path = output_dir / f"{basename}.key"
    pem_path = output_dir / f"{basename}.pem"

    cert_text, key_text = issue_remote_cert(
        ca_host=args.ca_host,
        common_name=common_name,
        sans=sans,
        bundle=True,
    )
    combined_text = cert_text + "\n" + key_text

    write_output(cert_path, cert_text, 0o644, force=args.force)
    write_output(key_path, key_text, 0o600, force=args.force)
    write_output(pem_path, combined_text, 0o600, force=args.force)

    print(
        json.dumps(
            {
                "kind": "unifi",
                "ca_host": args.ca_host,
                "common_name": common_name,
                "sans": sans,
                "cert_file": str(cert_path),
                "key_file": str(key_path),
                "pem_file": str(pem_path),
                "bundled": True,
            },
            sort_keys=True,
        )
    )


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
        description="Issue internal PKI certs for internal HTTPS services, or local UniFi Console import files.",
    )
    parser.add_argument("--host", help="Inventory host name, e.g. srvarr")
    parser.add_argument("--service", help="Internal HTTPS service name, e.g. glance")
    parser.add_argument(
        "--client", help="Internal HTTPS mTLS client identity name, e.g. vikunja"
    )
    parser.add_argument(
        "--unifi",
        action="store_true",
        help="Issue a UniFi Console cert and write local import files instead of updating sops secrets.",
    )
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        help="UniFi mode: directory where cert, private key, and combined PEM files are written.",
    )
    parser.add_argument(
        "--common-name",
        help=f"UniFi mode: certificate common name. Defaults to {unifi_common_name()}.",
    )
    parser.add_argument(
        "--san",
        action="append",
        default=[],
        help="UniFi mode: additional DNS or IP subjectAltName. May be passed more than once.",
    )
    parser.add_argument(
        "--include-gateway-ip",
        action="store_true",
        help="UniFi mode: also include the inventory gateway IP as a certificate subjectAltName.",
    )
    parser.add_argument(
        "--basename",
        help="UniFi mode: output filename basename. Defaults to the common name.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="UniFi mode: overwrite existing output files.",
    )
    parser.add_argument(
        "--ca-host", default=DEFAULT_CA_HOST, help="SSH host running step-ca"
    )
    args = parser.parse_args()

    if args.service and args.client:
        raise SystemExit("--service and --client are mutually exclusive")

    if args.unifi:
        if args.host or args.service or args.client:
            raise SystemExit(
                "--unifi cannot be combined with --host, --service, or --client"
            )
        if args.output_dir is None:
            parser.error("--output-dir is required with --unifi")
        validate_inventory_host(args.ca_host)
        issue_unifi(args)
        return

    unifi_only_options_used = any(
        [
            args.output_dir is not None,
            args.common_name is not None,
            bool(args.san),
            args.include_gateway_ip,
            args.basename is not None,
            args.force,
        ]
    )
    if unifi_only_options_used:
        raise SystemExit("UniFi output options require --unifi")
    if args.host is None:
        parser.error("--host is required unless --unifi is used")

    validate_inventory_host(args.host)
    validate_inventory_host(args.ca_host)
    host = args.host
    ca_host = args.ca_host

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
