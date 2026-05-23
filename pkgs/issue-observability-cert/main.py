#!/usr/bin/env python3
import argparse
import json
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_CA_HOST = "prox-pkivm"
DEFAULT_PROVISIONER = "bootstrap@home.arpa"
DEFAULT_PROVISIONER_PASSWORD_FILE = "/var/lib/step-ca/provisioner-password.txt"


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


def nix_segment(name):
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        return name
    return json.dumps(name)


def nix_attr_path(*segments):
    return ".#" + ".".join(nix_segment(segment) for segment in segments)


def nix_eval_json(*segments):
    raw = run(["nix", "eval", "--json", nix_attr_path(*segments)])
    return json.loads(raw)


def nix_eval_raw(*segments):
    return run(["nix", "eval", "--raw", nix_attr_path(*segments)]).strip()


def secret_path_for_host(host):
    return REPO_ROOT / "secrets" / f"{host}.yaml"


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


def endpoint_names_for_host(host):
    endpoint_map = nix_eval_json(
        "nixosConfigurations",
        host,
        "config",
        "host",
        "observability",
        "client",
        "prometheusMtlsEndpoints",
    )
    return sorted(name for name, endpoint in endpoint_map.items() if endpoint.get("enable"))


def endpoint_config(host, endpoint):
    return nix_eval_json(
        "nixosConfigurations",
        host,
        "config",
        "host",
        "observability",
        "client",
        "prometheusMtlsEndpoints",
        endpoint,
    )


def host_identity(host):
    return {
        "dns_name": nix_eval_raw("nixosConfigurations", host, "config", "host", "dnsName"),
        "avahi_name": nix_eval_raw("nixosConfigurations", host, "config", "services", "avahi", "hostName"),
        "networking_name": nix_eval_raw(
            "nixosConfigurations", host, "config", "networking", "hostName"
        ),
    }


def issue_remote_cert(*, ca_host, common_name, sans):
    san_args = " ".join(f"--san {shlex.quote(san)}" for san in sans)
    script = f"""
set -euo pipefail
tmpdir="$(mktemp -d)"
cleanup() {{
  sudo rm -rf "$tmpdir"
}}
trap cleanup EXIT
sudo step ca certificate {shlex.quote(common_name)} "$tmpdir/server.crt" "$tmpdir/server.key" \
  {san_args} \
  --provisioner {shlex.quote(DEFAULT_PROVISIONER)} \
  --provisioner-password-file {shlex.quote(DEFAULT_PROVISIONER_PASSWORD_FILE)} \
  >/dev/null
printf '%s\\n' '__CERT__'
sudo cat "$tmpdir/server.crt"
printf '%s\\n' '__KEY__'
sudo cat "$tmpdir/server.key"
"""
    output = run(["ssh", ca_host, "bash", "-lc", script], cwd=None)
    cert_marker = "__CERT__\n"
    key_marker = "\n__KEY__\n"
    if not output.startswith(cert_marker) or key_marker not in output:
        raise SystemExit("unexpected certificate output from CA host")
    cert_body = output[len(cert_marker) :]
    cert_text, key_text = cert_body.split(key_marker, 1)
    return cert_text.strip() + "\n", key_text.strip() + "\n"


def update_secret_file(host, endpoint, endpoint_cfg, cert_text, key_text):
    secret_path = secret_path_for_host(host)
    if not secret_path.exists():
        raise SystemExit(f"secret file not found: {secret_path}")

    run([str(REPO_ROOT / "scripts" / "sops-update.sh"), host])
    decrypted = run(["sops", "--decrypt", str(secret_path)])
    data = yaml.safe_load(decrypted) or {}

    prefix = endpoint_cfg["secretPrefix"].split("/")
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


def issue_endpoint(host, endpoint, *, ca_host):
    endpoint_cfg = endpoint_config(host, endpoint)
    identity = host_identity(host)
    sans = unique_strings(
        [
            identity["dns_name"],
            identity["networking_name"],
            identity["avahi_name"],
            f'{identity["avahi_name"]}.local',
        ]
    )
    common_name = f"prometheus-{endpoint}.{identity['dns_name']}"
    cert_text, key_text = issue_remote_cert(ca_host=ca_host, common_name=common_name, sans=sans)
    update_secret_file(host, endpoint, endpoint_cfg, cert_text, key_text)
    print(
        json.dumps(
            {
                "host": host,
                "endpoint": endpoint,
                "secret_prefix": endpoint_cfg["secretPrefix"],
                "port": endpoint_cfg["port"],
                "sans": sans,
            }
        )
    )


def main():
    parser = argparse.ArgumentParser(
        prog="issue-observability-cert",
        description="Issue internal PKI certs for Prometheus mTLS endpoints and store them in host sops secrets."
    )
    parser.add_argument("--host", required=True, help="Inventory host name, e.g. beast or prox-orgvm")
    parser.add_argument("--endpoint", help="Prometheus mTLS endpoint name, e.g. blackbox or smartctl")
    parser.add_argument("--ca-host", default=DEFAULT_CA_HOST, help="SSH host running step-ca")
    args = parser.parse_args()

    endpoints = [args.endpoint] if args.endpoint else endpoint_names_for_host(args.host)
    if not endpoints:
        raise SystemExit(f"host {args.host} has no configured Prometheus mTLS endpoints")

    for endpoint in endpoints:
        issue_endpoint(args.host, endpoint, ca_host=args.ca_host)


if __name__ == "__main__":
    main()
