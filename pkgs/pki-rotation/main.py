#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

import yaml
from cryptography import x509
from cryptography.x509.oid import NameOID


DEFAULT_REPO_ROOT_ENV = "PKI_ROTATION_REPO_ROOT"
DEFAULT_INTERMEDIATE_CERT_PATH = "/var/lib/step-ca/certs/intermediate_ca.crt"
DEFAULT_SOPS_AGE_KEY_FILE = "/var/lib/sops-nix/key.txt"
NODE_EXPORTER_ENDPOINT = "node_exporter"
NODE_EXPORTER_SECRET_PREFIX = "prometheus/node_exporter"


@dataclass(frozen=True)
class CertSpec:
    host: str
    category: str
    cert_name: str
    source_kind: str
    secret_host: str | None = None
    secret_prefix: str | None = None
    cert_field: str | None = None
    file_path: str | None = None


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


def normalize_repo_root(repo_root):
    if repo_root is None:
        return find_repo_root()
    return pathlib.Path(repo_root).expanduser().resolve()


def run(cmd, *, cwd=None, env=None, input_text=None):
    cwd = normalize_repo_root(cwd)
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        input=input_text,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return proc.stdout


def run_optional(cmd, *, cwd=None, env=None):
    cwd = normalize_repo_root(cwd)
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
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


def nix_eval_json(*segments, repo_root=None):
    repo_root = normalize_repo_root(repo_root)
    raw = run(["nix", "eval", "--json", nix_attr_path(*segments)], cwd=repo_root)
    return json.loads(raw)


def nix_eval_json_optional(*segments, repo_root=None):
    repo_root = normalize_repo_root(repo_root)
    raw = run_optional(
        ["nix", "eval", "--json", nix_attr_path(*segments)],
        cwd=repo_root,
    )
    if raw is None:
        return None
    return json.loads(raw)


def nix_eval_raw_optional(*segments, repo_root=None):
    repo_root = normalize_repo_root(repo_root)
    raw = run_optional(
        ["nix", "eval", "--raw", nix_attr_path(*segments)],
        cwd=repo_root,
    )
    if raw is None:
        return None
    return raw.strip()


def host_config_root(host, *, repo_root=None):
    repo_root = normalize_repo_root(repo_root)
    for root in ("nixosConfigurations", "darwinConfigurations"):
        if (
            nix_eval_raw_optional(
                root, host, "config", "host", "dnsName", repo_root=repo_root
            )
            is not None
        ):
            return root
    return None


def iter_secret_hosts(repo_root):
    secrets_dir = repo_root / "secrets"
    for path in sorted(secrets_dir.glob("*.yaml")):
        if path.name.startswith("_"):
            continue
        yield path.stem


def get_nested(mapping, dotted_path):
    cursor = mapping
    for key in dotted_path.split("/"):
        if not isinstance(cursor, dict) or key not in cursor:
            return None
        cursor = cursor[key]
    return cursor


def extract_first_pem_block(pem_text):
    match = re.search(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        pem_text,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("no PEM certificate block found")
    return match.group(0).encode("utf-8")


def common_name(name):
    values = name.get_attributes_for_oid(NameOID.COMMON_NAME)
    if not values:
        return ""
    return values[0].value


def cert_datetimes(cert):
    not_before = getattr(cert, "not_valid_before_utc", None)
    not_after = getattr(cert, "not_valid_after_utc", None)
    if not_before is None:
        not_before = cert.not_valid_before.replace(tzinfo=dt.timezone.utc)
    if not_after is None:
        not_after = cert.not_valid_after.replace(tzinfo=dt.timezone.utc)
    return not_before, not_after


def parse_cert_text(cert_text):
    cert = x509.load_pem_x509_certificate(extract_first_pem_block(cert_text))
    not_before, not_after = cert_datetimes(cert)
    return {
        "common_name": common_name(cert.subject),
        "issuer_common_name": common_name(cert.issuer),
        "not_before": not_before,
        "not_after": not_after,
    }


def decrypt_secret(secret_path, *, repo_root, sops_age_key_file):
    env = os.environ.copy()
    if sops_age_key_file:
        env["SOPS_AGE_KEY_FILE"] = sops_age_key_file
    decrypted = run(["sops", "--decrypt", str(secret_path)], cwd=repo_root, env=env)
    return yaml.safe_load(decrypted) or {}


def internal_https_service_specs(host, root, *, repo_root):
    service_map = (
        nix_eval_json_optional(
            root,
            host,
            "config",
            "host",
            "internalHttps",
            "services",
            repo_root=repo_root,
        )
        or {}
    )
    for service_name, service_cfg in sorted(service_map.items()):
        if not service_cfg.get("enable"):
            continue
        yield CertSpec(
            host=host,
            category="internal_https_server",
            cert_name=service_name,
            source_kind="repo_secret",
            secret_host=host,
            secret_prefix=service_cfg["secretPrefix"],
            cert_field="server_crt",
        )


def observability_endpoint_specs(host, root, *, repo_root):
    node_exporter_enabled = bool(
        nix_eval_json_optional(
            root,
            host,
            "config",
            "host",
            "observability",
            "client",
            "nodeExporter",
            "mtls",
            "enable",
            repo_root=repo_root,
        )
    )
    if node_exporter_enabled:
        yield CertSpec(
            host=host,
            category="observability_endpoint_server",
            cert_name=NODE_EXPORTER_ENDPOINT,
            source_kind="repo_secret",
            secret_host=host,
            secret_prefix=NODE_EXPORTER_SECRET_PREFIX,
            cert_field="server_crt",
        )

    endpoint_map = (
        nix_eval_json_optional(
            root,
            host,
            "config",
            "host",
            "observability",
            "client",
            "prometheusMtlsEndpoints",
            repo_root=repo_root,
        )
        or {}
    )
    for endpoint_name, endpoint_cfg in sorted(endpoint_map.items()):
        if endpoint_name == NODE_EXPORTER_ENDPOINT or not endpoint_cfg.get("enable"):
            continue
        yield CertSpec(
            host=host,
            category="observability_endpoint_server",
            cert_name=endpoint_name,
            source_kind="repo_secret",
            secret_host=host,
            secret_prefix=endpoint_cfg["secretPrefix"],
            cert_field="server_crt",
        )


def observability_client_specs(host, root, *, repo_root):
    client_map = (
        nix_eval_json_optional(
            root,
            host,
            "config",
            "host",
            "observability",
            "client",
            "mtlsClients",
            repo_root=repo_root,
        )
        or {}
    )
    for client_name, client_cfg in sorted(client_map.items()):
        if not client_cfg.get("enable"):
            continue
        yield CertSpec(
            host=host,
            category="observability_client",
            cert_name=client_name,
            source_kind="repo_secret",
            secret_host=host,
            secret_prefix=client_cfg["secretPrefix"],
            cert_field="client_crt",
        )


def external_service_client_specs(host, root, *, repo_root):
    client_map = (
        nix_eval_json_optional(
            root,
            host,
            "config",
            "host",
            "externalService",
            "mtlsClients",
            repo_root=repo_root,
        )
        or {}
    )
    for client_name, client_cfg in sorted(client_map.items()):
        if not client_cfg.get("enable"):
            continue
        yield CertSpec(
            host=host,
            category="external_service_client",
            cert_name=client_name,
            source_kind="repo_secret",
            secret_host=host,
            secret_prefix=client_cfg["secretPrefix"],
            cert_field="client_crt",
        )


def cert_specs(repo_root, *, intermediate_cert_path):
    yield CertSpec(
        host="prox-pkivm",
        category="ca",
        cert_name="root",
        source_kind="repo_file",
        file_path=str(
            repo_root
            / "common"
            / "_mixins"
            / "internal-pki"
            / "home-internal-pki-root-ca.crt"
        ),
    )
    yield CertSpec(
        host="prox-pkivm",
        category="ca",
        cert_name="intermediate",
        source_kind="host_file",
        file_path=intermediate_cert_path,
    )

    for host in iter_secret_hosts(repo_root):
        root = host_config_root(host, repo_root=repo_root)
        if root is None:
            continue
        yield from internal_https_service_specs(host, root, repo_root=repo_root)
        yield from observability_endpoint_specs(host, root, repo_root=repo_root)
        yield from observability_client_specs(host, root, repo_root=repo_root)
        yield from external_service_client_specs(host, root, repo_root=repo_root)


def load_cert_text(spec, *, repo_root, sops_age_key_file, secret_cache):
    if spec.source_kind in {"repo_file", "host_file"}:
        path = pathlib.Path(spec.file_path)
        if not path.exists():
            return None
        return path.read_text()

    if spec.secret_host not in secret_cache:
        secret_path = repo_root / "secrets" / f"{spec.secret_host}.yaml"
        secret_cache[spec.secret_host] = decrypt_secret(
            secret_path,
            repo_root=repo_root,
            sops_age_key_file=sops_age_key_file,
        )
    secret_data = secret_cache[spec.secret_host]
    value = get_nested(secret_data, f"{spec.secret_prefix}/{spec.cert_field}")
    if not isinstance(value, str):
        return None
    return value


def scan_certs(
    repo_root, *, intermediate_cert_path, rotation_window_days, sops_age_key_file
):
    repo_root = normalize_repo_root(repo_root)
    now = dt.datetime.now(dt.timezone.utc)
    secret_cache = {}
    records = []
    for spec in cert_specs(repo_root, intermediate_cert_path=intermediate_cert_path):
        record = {
            "host": spec.host,
            "category": spec.category,
            "cert_name": spec.cert_name,
            "source_kind": spec.source_kind,
            "secret_host": spec.secret_host,
            "secret_prefix": spec.secret_prefix,
            "parse_success": 0,
            "rotation_due": 1,
        }
        cert_text = load_cert_text(
            spec,
            repo_root=repo_root,
            sops_age_key_file=sops_age_key_file,
            secret_cache=secret_cache,
        )
        if cert_text is None or cert_text.strip() in {"", "REPLACE_ME"}:
            records.append(record)
            continue

        try:
            parsed = parse_cert_text(cert_text)
        except Exception as exc:  # noqa: BLE001
            record["parse_error"] = str(exc)
            records.append(record)
            continue

        seconds_remaining = (parsed["not_after"] - now).total_seconds()
        record.update(
            {
                "parse_success": 1,
                "common_name": parsed["common_name"],
                "issuer_common_name": parsed["issuer_common_name"],
                "not_before_timestamp_seconds": parsed["not_before"].timestamp(),
                "not_after_timestamp_seconds": parsed["not_after"].timestamp(),
                "days_remaining": seconds_remaining / 86400,
                "rotation_due": 1
                if seconds_remaining <= rotation_window_days * 86400
                else 0,
            }
        )
        records.append(record)

    records.sort(key=lambda item: (item["category"], item["host"], item["cert_name"]))
    return records


def escape_label_value(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def format_metric(name, value, labels):
    rendered_labels = ",".join(
        f'{key}="{escape_label_value(labels[key])}"' for key in sorted(labels)
    )
    return f"{name}{{{rendered_labels}}} {value}"


def metrics_text(records):
    lines = [
        "# HELP host_observability_pki_cert_expected Whether a managed PKI certificate is expected to exist.",
        "# TYPE host_observability_pki_cert_expected gauge",
    ]
    for record in records:
        labels = {
            "host": record["host"],
            "category": record["category"],
            "cert_name": record["cert_name"],
        }
        lines.append(format_metric("host_observability_pki_cert_expected", 1, labels))

    lines.extend(
        [
            "# HELP host_observability_pki_cert_parse_success Whether a managed PKI certificate was present and parsed successfully.",
            "# TYPE host_observability_pki_cert_parse_success gauge",
        ]
    )
    for record in records:
        labels = {
            "host": record["host"],
            "category": record["category"],
            "cert_name": record["cert_name"],
        }
        lines.append(
            format_metric(
                "host_observability_pki_cert_parse_success",
                record["parse_success"],
                labels,
            )
        )

    lines.extend(
        [
            "# HELP host_observability_pki_cert_rotation_due Whether a managed PKI certificate is inside the configured rotation window.",
            "# TYPE host_observability_pki_cert_rotation_due gauge",
        ]
    )
    for record in records:
        labels = {
            "host": record["host"],
            "category": record["category"],
            "cert_name": record["cert_name"],
        }
        lines.append(
            format_metric(
                "host_observability_pki_cert_rotation_due",
                record["rotation_due"],
                labels,
            )
        )

    lines.extend(
        [
            "# HELP host_observability_pki_cert_not_before_timestamp_seconds Not-before timestamp of a managed PKI certificate.",
            "# TYPE host_observability_pki_cert_not_before_timestamp_seconds gauge",
            "# HELP host_observability_pki_cert_not_after_timestamp_seconds Not-after timestamp of a managed PKI certificate.",
            "# TYPE host_observability_pki_cert_not_after_timestamp_seconds gauge",
            "# HELP host_observability_pki_cert_days_remaining Remaining lifetime of a managed PKI certificate in days.",
            "# TYPE host_observability_pki_cert_days_remaining gauge",
            "# HELP host_observability_pki_cert_info Static metadata about a managed PKI certificate.",
            "# TYPE host_observability_pki_cert_info gauge",
        ]
    )
    for record in records:
        if record["parse_success"] != 1:
            continue
        labels = {
            "host": record["host"],
            "category": record["category"],
            "cert_name": record["cert_name"],
        }
        lines.append(
            format_metric(
                "host_observability_pki_cert_not_before_timestamp_seconds",
                record["not_before_timestamp_seconds"],
                labels,
            )
        )
        lines.append(
            format_metric(
                "host_observability_pki_cert_not_after_timestamp_seconds",
                record["not_after_timestamp_seconds"],
                labels,
            )
        )
        lines.append(
            format_metric(
                "host_observability_pki_cert_days_remaining",
                f"{record['days_remaining']:.6f}",
                labels,
            )
        )
        lines.append(
            format_metric(
                "host_observability_pki_cert_info",
                1,
                labels
                | {
                    "common_name": record.get("common_name", ""),
                    "issuer_common_name": record.get("issuer_common_name", ""),
                },
            )
        )

    return "\n".join(lines) + "\n"


def rotation_metrics_text(summary):
    labels = {
        "branch": summary["branch"],
        "base_branch": summary["base_branch"],
    }
    lines = [
        "# HELP host_observability_pki_rotation_last_run_timestamp_seconds Last completion time of the PKI rotation controller.",
        "# TYPE host_observability_pki_rotation_last_run_timestamp_seconds gauge",
        format_metric(
            "host_observability_pki_rotation_last_run_timestamp_seconds",
            summary["run_timestamp_seconds"],
            labels,
        ),
        "# HELP host_observability_pki_rotation_last_success Whether the last PKI rotation controller run completed successfully.",
        "# TYPE host_observability_pki_rotation_last_success gauge",
        format_metric(
            "host_observability_pki_rotation_last_success",
            1 if summary["success"] else 0,
            labels,
        ),
        "# HELP host_observability_pki_rotation_last_due_count Number of certificates inside the rotation window on the last controller run.",
        "# TYPE host_observability_pki_rotation_last_due_count gauge",
        format_metric(
            "host_observability_pki_rotation_last_due_count",
            summary["due_count"],
            labels,
        ),
        "# HELP host_observability_pki_rotation_last_rotated_count Number of certificates actually reissued on the last controller run.",
        "# TYPE host_observability_pki_rotation_last_rotated_count gauge",
        format_metric(
            "host_observability_pki_rotation_last_rotated_count",
            summary["rotated_count"],
            labels,
        ),
        "# HELP host_observability_pki_rotation_last_pr_open Whether the controller left an open PR branch to review.",
        "# TYPE host_observability_pki_rotation_last_pr_open gauge",
        format_metric(
            "host_observability_pki_rotation_last_pr_open",
            1 if summary["pr_url"] else 0,
            labels,
        ),
    ]
    return "\n".join(lines) + "\n"


def write_atomic(path, content):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        dir=target.parent,
        prefix=f"{target.name}.",
        delete=False,
    ) as handle:
        handle.write(content)
        tmp_path = pathlib.Path(handle.name)
    tmp_path.replace(target)


def rotation_candidates(records):
    return [
        record
        for record in records
        if record["category"] != "ca" and record["rotation_due"] == 1
    ]


def issue_command_for_record(record):
    category = record["category"]
    if category == "internal_https_server":
        return [
            "issue-internal-service-cert",
            "--host",
            record["host"],
            "--service",
            record["cert_name"],
        ]
    if category == "external_service_client":
        return [
            "issue-internal-service-cert",
            "--host",
            record["host"],
            "--client",
            record["cert_name"],
        ]
    if category == "observability_endpoint_server":
        return [
            "issue-observability-cert",
            "--host",
            record["host"],
            "--endpoint",
            record["cert_name"],
        ]
    if category == "observability_client":
        return [
            "issue-observability-cert",
            "--host",
            record["host"],
            "--client",
            record["cert_name"],
        ]
    raise SystemExit(f"unsupported rotation category: {category}")


def apply_rotations(candidates, *, repo_root, sops_age_key_file):
    env = os.environ.copy()
    env["ISSUE_CERT_LOCAL_CA"] = "1"
    if sops_age_key_file:
        env["SOPS_AGE_KEY_FILE"] = sops_age_key_file

    rotated = []
    for record in candidates:
        output = run(issue_command_for_record(record), cwd=repo_root, env=env)
        payload = {}
        if output.strip():
            try:
                payload = json.loads(output.strip().splitlines()[-1])
            except json.JSONDecodeError:
                payload = {"raw_output": output.strip()}
        rotated.append(record | {"issuer_result": payload})
    return rotated


def git_has_changes(repo_root):
    return bool(run(["git", "status", "--short"], cwd=repo_root).strip())


def read_token(token_file):
    token = pathlib.Path(token_file).read_text().strip()
    if not token:
        raise SystemExit(f"token file is empty: {token_file}")
    return token


def prepare_git_auth_env(token_file):
    env = os.environ.copy()
    cleanup_paths = []
    if not token_file:
        return env, cleanup_paths

    token_path = pathlib.Path(token_file).resolve()
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
        handle.write(
            """#!/bin/sh
case "$1" in
  *sername*) printf '%s\\n' 'x-access-token' ;;
  *assword*) cat "$PKI_ROTATION_GITHUB_TOKEN_FILE" ;;
  *) printf '\\n' ;;
esac
"""
        )
        askpass_path = pathlib.Path(handle.name)
    askpass_path.chmod(0o700)
    cleanup_paths.append(askpass_path)
    env.update(
        {
            "GIT_ASKPASS": str(askpass_path),
            "GIT_TERMINAL_PROMPT": "0",
            "PKI_ROTATION_GITHUB_TOKEN_FILE": str(token_path),
        }
    )
    return env, cleanup_paths


def github_api_json(method, path, *, token, payload=None):
    data = None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        data=data,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"GitHub API request failed: {exc} {details}") from exc

    if not body:
        return None
    return json.loads(body.decode("utf-8"))


def find_open_pr(owner, repo_name, *, branch, base_branch, token):
    query = urllib.parse.urlencode(
        {
            "state": "open",
            "head": f"{owner}:{branch}",
            "base": base_branch,
        }
    )
    pulls = github_api_json(
        "GET",
        f"/repos/{owner}/{repo_name}/pulls?{query}",
        token=token,
    )
    if not pulls:
        return None
    return pulls[0]


def format_expiry(record):
    if record.get("parse_success") != 1:
        return "unparsable"
    return (
        dt.datetime.fromtimestamp(
            record["not_after_timestamp_seconds"], tz=dt.timezone.utc
        )
        .date()
        .isoformat()
    )


def build_pr_body(rotated_records, records_after, *, rotation_window_days):
    lookup = {
        (record["host"], record["category"], record["cert_name"]): record
        for record in records_after
    }
    lines = [
        "## Summary",
        f"- rotate {len(rotated_records)} managed internal PKI leaf cert(s)",
        "- leaf lifetime: 180d",
        f"- rotation window: {rotation_window_days}d",
        "",
        "## Rotated Certificates",
    ]
    for record in rotated_records:
        refreshed = lookup[(record["host"], record["category"], record["cert_name"])]
        lines.append(
            f"- `{record['host']}` / `{record['category']}` / `{record['cert_name']}` -> expires `{format_expiry(refreshed)}`"
        )
    lines.extend(
        [
            "",
            "This PR was created automatically by `prox-pkivm`.",
        ]
    )
    return "\n".join(lines) + "\n"


def cmd_rotate(args):
    run_timestamp = dt.datetime.now(dt.timezone.utc).timestamp()

    if args.dry_run:
        records = scan_certs(
            args.repo_root,
            intermediate_cert_path=args.intermediate_cert_path,
            rotation_window_days=args.rotation_window_days,
            sops_age_key_file=args.sops_age_key_file,
        )
        candidates = rotation_candidates(records)
        summary = {
            "success": True,
            "dry_run": True,
            "branch": args.branch,
            "base_branch": args.base_branch,
            "run_timestamp_seconds": run_timestamp,
            "due_count": len(candidates),
            "rotated_count": 0,
            "pr_url": None,
            "candidates": candidates,
        }
        if args.metrics_output:
            write_atomic(args.metrics_output, rotation_metrics_text(summary))
        print(json.dumps(summary, indent=2, sort_keys=True))
        return

    if not args.github_token_file:
        raise SystemExit("--github-token-file is required unless --dry-run is used")

    token = read_token(args.github_token_file)
    open_pr = find_open_pr(
        args.repo_owner,
        args.repo_name,
        branch=args.branch,
        base_branch=args.base_branch,
        token=token,
    )

    git_env, cleanup_paths = prepare_git_auth_env(args.github_token_file)
    try:
        with tempfile.TemporaryDirectory(prefix="pki-rotation-") as tmpdir:
            worktree = pathlib.Path(tmpdir) / "repo"
            clone_branch = args.branch if open_pr else args.base_branch
            run(
                [
                    "git",
                    "clone",
                    "--branch",
                    clone_branch,
                    "--single-branch",
                    args.repo_url,
                    str(worktree),
                ],
                cwd=None,
                env=git_env,
            )
            if not open_pr:
                run(["git", "switch", "-c", args.branch], cwd=worktree, env=git_env)

            records_before = scan_certs(
                worktree,
                intermediate_cert_path=args.intermediate_cert_path,
                rotation_window_days=args.rotation_window_days,
                sops_age_key_file=args.sops_age_key_file,
            )
            candidates = rotation_candidates(records_before)

            if candidates:
                rotated = apply_rotations(
                    candidates,
                    repo_root=worktree,
                    sops_age_key_file=args.sops_age_key_file,
                )
            else:
                rotated = []

            records_after = scan_certs(
                worktree,
                intermediate_cert_path=args.intermediate_cert_path,
                rotation_window_days=args.rotation_window_days,
                sops_age_key_file=args.sops_age_key_file,
            )

            pr_url = open_pr["html_url"] if open_pr else None
            rotated_count = len(rotated)

            if rotated and git_has_changes(worktree):
                run(
                    ["git", "config", "user.name", args.commit_user_name],
                    cwd=worktree,
                    env=git_env,
                )
                run(
                    ["git", "config", "user.email", args.commit_user_email],
                    cwd=worktree,
                    env=git_env,
                )
                run(["git", "add", "secrets"], cwd=worktree, env=git_env)
                run(
                    [
                        "git",
                        "commit",
                        "-m",
                        "chore: rotate internal PKI leaf certs",
                    ],
                    cwd=worktree,
                    env=git_env,
                )
                run(
                    [
                        "git",
                        "push",
                        "--force-with-lease",
                        "origin",
                        f"HEAD:{args.branch}",
                    ],
                    cwd=worktree,
                    env=git_env,
                )

                if open_pr is None:
                    created_pr = github_api_json(
                        "POST",
                        f"/repos/{args.repo_owner}/{args.repo_name}/pulls",
                        token=token,
                        payload={
                            "title": "chore: rotate internal PKI leaf certs",
                            "head": args.branch,
                            "base": args.base_branch,
                            "body": build_pr_body(
                                rotated,
                                records_after,
                                rotation_window_days=args.rotation_window_days,
                            ),
                        },
                    )
                    pr_url = created_pr["html_url"]
                else:
                    pr_url = open_pr["html_url"]

            summary = {
                "success": True,
                "dry_run": False,
                "branch": args.branch,
                "base_branch": args.base_branch,
                "run_timestamp_seconds": run_timestamp,
                "due_count": len(candidates),
                "rotated_count": rotated_count,
                "pr_url": pr_url,
                "rotated": [
                    {
                        "host": record["host"],
                        "category": record["category"],
                        "cert_name": record["cert_name"],
                    }
                    for record in rotated
                ],
            }
            if args.metrics_output:
                write_atomic(args.metrics_output, rotation_metrics_text(summary))
            print(json.dumps(summary, indent=2, sort_keys=True))
    finally:
        for path in cleanup_paths:
            path.unlink(missing_ok=True)


def cmd_scan(args):
    records = scan_certs(
        args.repo_root,
        intermediate_cert_path=args.intermediate_cert_path,
        rotation_window_days=args.rotation_window_days,
        sops_age_key_file=args.sops_age_key_file,
    )
    print(json.dumps(records, indent=2, sort_keys=True))


def cmd_export_metrics(args):
    records = scan_certs(
        args.repo_root,
        intermediate_cert_path=args.intermediate_cert_path,
        rotation_window_days=args.rotation_window_days,
        sops_age_key_file=args.sops_age_key_file,
    )
    content = metrics_text(records)
    if args.output:
        write_atomic(args.output, content)
    else:
        sys.stdout.write(content)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="pki-rotation",
        description="Inspect repo-managed internal PKI certificates and export rotation status.",
    )
    parser.add_argument(
        "--repo-root",
        type=pathlib.Path,
        default=None,
        help=(
            "Flake checkout to inspect. Defaults to the current checkout or "
            f"${DEFAULT_REPO_ROOT_ENV}."
        ),
    )
    parser.add_argument(
        "--rotation-window-days",
        type=int,
        default=45,
        help="Certificates inside this many days are considered due for rotation.",
    )
    parser.add_argument(
        "--intermediate-cert-path",
        default=DEFAULT_INTERMEDIATE_CERT_PATH,
        help="Path to the step-ca intermediate certificate on pkivm.",
    )
    parser.add_argument(
        "--sops-age-key-file",
        default=os.environ.get("SOPS_AGE_KEY_FILE", DEFAULT_SOPS_AGE_KEY_FILE),
        help="Age private key used to decrypt repo-managed secrets.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    scan_parser = subparsers.add_parser(
        "scan", help="Print managed certificate inventory as JSON."
    )
    scan_parser.set_defaults(func=cmd_scan)

    export_parser = subparsers.add_parser(
        "export-metrics",
        help="Export managed certificate status as Prometheus textfile metrics.",
    )
    export_parser.add_argument(
        "--output",
        help="Write Prometheus metrics atomically to this path instead of stdout.",
    )
    export_parser.set_defaults(func=cmd_export_metrics)

    rotate_parser = subparsers.add_parser(
        "rotate",
        help="Rotate due managed leaf certificates and open a review PR.",
    )
    rotate_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report due certificates without cloning, reissuing, or opening a PR.",
    )
    rotate_parser.add_argument(
        "--github-token-file",
        help="Secret file containing a GitHub token able to push a branch and create a PR.",
    )
    rotate_parser.add_argument(
        "--repo-url",
        default="https://github.com/booxter/nix.git",
        help="Git URL used for the writable rotation checkout.",
    )
    rotate_parser.add_argument(
        "--repo-owner",
        default="booxter",
        help="GitHub repository owner used for PR lookup and creation.",
    )
    rotate_parser.add_argument(
        "--repo-name",
        default="nix",
        help="GitHub repository name used for PR lookup and creation.",
    )
    rotate_parser.add_argument(
        "--base-branch",
        default="master",
        help="Base branch the rotation PR should target.",
    )
    rotate_parser.add_argument(
        "--branch",
        default="ci/pki-rotate",
        help="Automation branch used for the rotation PR.",
    )
    rotate_parser.add_argument(
        "--commit-user-name",
        default="PKI Rotation Bot",
        help="Git commit author name for automated rotation commits.",
    )
    rotate_parser.add_argument(
        "--commit-user-email",
        default="pki-rotation@home.arpa",
        help="Git commit author email for automated rotation commits.",
    )
    rotate_parser.add_argument(
        "--metrics-output",
        help="Optional Prometheus textfile path for controller run metrics.",
    )
    rotate_parser.set_defaults(func=cmd_rotate)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if args.repo_root is not None:
        args.repo_root = normalize_repo_root(args.repo_root)
    args.func(args)


if __name__ == "__main__":
    main()
