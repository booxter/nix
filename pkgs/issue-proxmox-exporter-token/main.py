#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys


DEFAULT_REPO_ROOT_ENV = "ISSUE_PROXMOX_EXPORTER_TOKEN_REPO_ROOT"
DEFAULT_API_USER = "prometheus@pve"
DEFAULT_TOKEN_NAME = "metrics"
DEFAULT_ROLE = "PVEAuditor"
DEFAULT_ACL_PATH = "/"


def find_repo_root():
    env_root = os.environ.get(DEFAULT_REPO_ROOT_ENV)
    if env_root:
        candidate = pathlib.Path(env_root).expanduser().resolve()
        if (candidate / "flake.nix").exists():
            return candidate
        raise SystemExit(
            f"{DEFAULT_REPO_ROOT_ENV} does not point to a flake checkout: {candidate}"
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
        f"could not determine repo root; run from the checkout or set {DEFAULT_REPO_ROOT_ENV}"
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


def nix_segment(name):
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        return name
    return json.dumps(name)


def nix_attr_path(*segments):
    return ".#" + ".".join(nix_segment(segment) for segment in segments)


def nix_eval_json(*segments):
    return json.loads(run(["nix", "eval", "--json", nix_attr_path(*segments)]))


def secret_path_for_host(host):
    return REPO_ROOT / "secrets" / f"{host}.yaml"


def sops_index_path(secret_key):
    return "".join(f"[{json.dumps(segment)}]" for segment in secret_key.split("/"))


def enabled_exporter_hosts():
    apply_expr = """
configs:
builtins.filter
  (name:
    !((configs.${name}.config.host.isWork or false))
    && ((configs.${name}.config.host.proxmox.prometheusExporter.enable or false) == true))
  (builtins.attrNames configs)
"""
    return json.loads(
        run(
            [
                "nix",
                "eval",
                "--json",
                "--apply",
                apply_expr,
                ".#nixosConfigurations",
            ]
        )
    )


def exporter_config(host):
    return nix_eval_json(
        "nixosConfigurations",
        host,
        "config",
        "host",
        "proxmox",
        "prometheusExporter",
    )


def validate_secret_hosts(hosts, *, api_user, token_name):
    if not hosts:
        raise SystemExit("no Proxmox exporter hosts selected")

    host_configs = {}
    for host in hosts:
        cfg = exporter_config(host)
        if not cfg.get("enable"):
            raise SystemExit(
                f"host {host} does not have host.proxmox.prometheusExporter.enable"
            )
        if cfg["apiUser"] != api_user:
            raise SystemExit(
                f"host {host} expects apiUser={cfg['apiUser']!r}, not {api_user!r}"
            )
        if cfg["apiTokenName"] != token_name:
            raise SystemExit(
                f"host {host} expects apiTokenName={cfg['apiTokenName']!r}, not {token_name!r}"
            )
        host_configs[host] = cfg
    return host_configs


def parse_token_value(output):
    stripped = output.strip()
    json_start = stripped.find("{")
    json_end = stripped.rfind("}")
    if json_start >= 0 and json_end > json_start:
        payload = json.loads(stripped[json_start : json_end + 1])
        for candidate in [
            payload,
            payload.get("data") if isinstance(payload, dict) else None,
        ]:
            if isinstance(candidate, dict) and candidate.get("value"):
                return candidate["value"]

    for line in stripped.splitlines():
        if "value" not in line:
            continue
        match = re.search(r"value\s*[│|: ]+\s*([A-Za-z0-9._~+/=-]+)", line)
        if match:
            return match.group(1)

    raise SystemExit("could not parse token value from pveum output")


def issue_token(
    *,
    issuer_host,
    api_user,
    token_name,
    role,
    acl_path,
    replace,
    comment,
):
    quoted_comment = shlex.quote(comment)
    replace_value = "1" if replace else "0"
    script = f"""
set -euo pipefail
api_user={shlex.quote(api_user)}
token_name={shlex.quote(token_name)}
role={shlex.quote(role)}
acl_path={shlex.quote(acl_path)}
replace={shlex.quote(replace_value)}

pveum() {{
  if [ "$(id -u)" -eq 0 ]; then
    command pveum "$@"
  else
    sudo -n pveum "$@"
  fi
}}

if ! pveum user list --output-format json | grep -F "\\"$api_user\\"" >/dev/null; then
  pveum user add "$api_user" --comment {quoted_comment} >/dev/null
fi

pveum aclmod "$acl_path" -user "$api_user" -role "$role" >/dev/null

if [ "$replace" = "1" ]; then
  pveum user token remove "$api_user" "$token_name" >/dev/null 2>&1 || true
fi

pveum user token add "$api_user" "$token_name" --privsep 0 --output-format json
"""
    output = run(["ssh", issuer_host, "bash", "-s"], cwd=None, input_text=script)
    return parse_token_value(output)


def update_secret_file(host, secret_key, token_value):
    secret_path = secret_path_for_host(host)
    if not secret_path.exists():
        raise SystemExit(f"secret file not found: {secret_path}")

    run(
        [
            "sops",
            "set",
            "--input-type",
            "yaml",
            "--output-type",
            "yaml",
            "--value-stdin",
            str(secret_path),
            sops_index_path(secret_key),
        ],
        input_text=json.dumps(token_value),
    )


def main():
    parser = argparse.ArgumentParser(
        prog="issue-proxmox-exporter-token",
        description="Issue the Proxmox VE prometheus-pve-exporter API token and store it in host sops secrets.",
    )
    parser.add_argument(
        "--issuer-host",
        help="Proxmox node to run pveum on. Defaults to the first selected secret host.",
    )
    parser.add_argument(
        "--secret-host",
        action="append",
        dest="secret_hosts",
        help="Host sops secret to update. Repeat to override the default enabled lab Proxmox hosts.",
    )
    parser.add_argument("--user", default=DEFAULT_API_USER, help="Proxmox API user.")
    parser.add_argument(
        "--token-name", default=DEFAULT_TOKEN_NAME, help="Proxmox API token name."
    )
    parser.add_argument("--role", default=DEFAULT_ROLE, help="Role to grant.")
    parser.add_argument("--path", default=DEFAULT_ACL_PATH, help="ACL path to grant.")
    parser.add_argument(
        "--replace",
        action="store_true",
        help="Remove any existing token with the same name before issuing a new value.",
    )
    parser.add_argument(
        "--token-value",
        help="Skip remote token creation and only write this existing token value to sops.",
    )
    parser.add_argument(
        "--token-value-file",
        help="Read an existing token value from a file and only write it to sops.",
    )
    parser.add_argument(
        "--comment",
        default="Prometheus PVE exporter metrics user",
        help="Comment for a newly-created Proxmox user.",
    )
    args = parser.parse_args()
    if args.token_value and args.token_value_file:
        raise SystemExit("--token-value and --token-value-file are mutually exclusive")

    secret_hosts = args.secret_hosts or enabled_exporter_hosts()
    host_configs = validate_secret_hosts(
        secret_hosts, api_user=args.user, token_name=args.token_name
    )
    issuer_host = args.issuer_host or secret_hosts[0]

    token_value = args.token_value
    if args.token_value_file:
        token_value = pathlib.Path(args.token_value_file).read_text().strip()
    if token_value is None:
        token_value = issue_token(
            issuer_host=issuer_host,
            api_user=args.user,
            token_name=args.token_name,
            role=args.role,
            acl_path=args.path,
            replace=args.replace,
            comment=args.comment,
        )

    updated_hosts = []
    for host in secret_hosts:
        update_secret_file(host, host_configs[host]["apiTokenValueSecret"], token_value)
        updated_hosts.append(host)

    print(
        json.dumps(
            {
                "issuer_host": issuer_host,
                "user": args.user,
                "token_name": args.token_name,
                "role": args.role,
                "path": args.path,
                "updated_hosts": updated_hosts,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
