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


REPO_ROOT = find_repo_root()


def run(cmd, *, cwd=REPO_ROOT, env=None, input_text=None):
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


def run_optional(cmd, *, cwd=REPO_ROOT, env=None):
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


def nix_eval_json(*segments, repo_root=REPO_ROOT):
    raw = run(["nix", "eval", "--json", nix_attr_path(*segments)], cwd=repo_root)
    return json.loads(raw)


def nix_eval_json_optional(*segments, repo_root=REPO_ROOT):
    raw = run_optional(
        ["nix", "eval", "--json", nix_attr_path(*segments)],
        cwd=repo_root,
    )
    if raw is None:
        return None
    return json.loads(raw)


def nix_eval_raw_optional(*segments, repo_root=REPO_ROOT):
    raw = run_optional(
        ["nix", "eval", "--raw", nix_attr_path(*segments)],
        cwd=repo_root,
    )
    if raw is None:
        return None
    return raw.strip()


def host_config_root(host, *, repo_root=REPO_ROOT):
    for root in ("nixosConfigurations", "darwinConfigurations"):
        if (
            nix_eval_raw_optional(root, host, "config", "host", "dnsName", repo_root=repo_root)
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
            repo_root / "common" / "_mixins" / "internal-pki" / "home-internal-pki-root-ca.crt"
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


def scan_certs(repo_root, *, intermediate_cert_path, rotation_window_days, sops_age_key_file):
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
                "rotation_due": 1 if seconds_remaining <= rotation_window_days * 86400 else 0,
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
        default=REPO_ROOT,
        help=f"Flake checkout to inspect (default: {REPO_ROOT})",
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

    scan_parser = subparsers.add_parser("scan", help="Print managed certificate inventory as JSON.")
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

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.repo_root = args.repo_root.resolve()
    args.func(args)


if __name__ == "__main__":
    main()
