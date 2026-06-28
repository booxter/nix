#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time


DEFAULT_CA_PRIVATE_KEY = "~/.ssh/fleet-user-ca"
DEFAULT_CA_PUBLIC_KEY = "~/.ssh/fleet-user-ca.pub"
DEFAULT_KEY = "~/.ssh/fleet-ticket/id_ed25519"
TARGETS_FILE_ENV = "SSHT_TARGETS_FILE"
MIN_VALID_SECONDS = 60
COMMON_TTL_CHOICES = (30 * 60, 60 * 60, 2 * 60 * 60, 12 * 60 * 60)


class Error(Exception):
    pass


def expand_path(value):
    return pathlib.Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def default_state_dir():
    xdg_state = os.environ.get("XDG_STATE_HOME")
    if xdg_state:
        return expand_path(f"{xdg_state}/ssh-ticket")
    return expand_path("~/.local/state/ssh-ticket")


def state_dir_arg(args):
    return expand_path(args.state_dir) if args.state_dir else default_state_dir()


def run(cmd, *, input_text=None, capture=True):
    proc = subprocess.run(
        cmd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if proc.returncode != 0:
        if capture and proc.stderr:
            sys.stderr.write(proc.stderr)
        raise Error(f"command failed: {shlex_join(cmd)}")
    return proc.stdout if capture else ""


def shlex_join(cmd):
    return " ".join(shell_quote(str(part)) for part in cmd)


def shell_quote(value):
    if re.fullmatch(r"[A-Za-z0-9_@%+=:,./-]+", value):
        return value
    return "'" + value.replace("'", "'\\''") + "'"


def applescript_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def applescript_string(value):
    return " & linefeed & ".join(applescript_quote(part) for part in value.split("\n"))


def osascript_approval_script(message):
    return f"""
      tell application "System Events"
        activate
        set response to display dialog {applescript_string(message)} buttons {{"Deny", "Approve"}} default button "Approve" cancel button "Deny" with title "ssht"
        return button returned of response
      end tell
    """


def osascript_ttl_selector_script(message, choices, default_answer):
    message = f"{message}\n\nTTL choices: {', '.join(choices)}"
    return f"""
      tell application "System Events"
        activate
        set response to display dialog {applescript_string(message)} default answer {applescript_quote(default_answer)} buttons {{"Deny", "Approve"}} default button "Approve" cancel button "Deny" with title "ssht"
        return text returned of response
      end tell
    """


def parse_duration(value):
    if isinstance(value, int):
        return value
    text = str(value).strip().lower()
    if not text:
        raise Error("duration must not be empty")
    units = {
        "": 1,
        "s": 1,
        "m": 60,
        "h": 60 * 60,
        "d": 24 * 60 * 60,
        "w": 7 * 24 * 60 * 60,
    }
    total = 0
    pos = 0
    for match in re.finditer(r"(\d+)([smhdw]?)", text):
        if match.start() != pos:
            raise Error(f"invalid duration: {value}")
        amount = int(match.group(1))
        unit = match.group(2)
        total += amount * units[unit]
        pos = match.end()
    if pos != len(text) or total <= 0:
        raise Error(f"invalid duration: {value}")
    return total


def format_duration(seconds):
    seconds = int(seconds)
    for unit, size in (("w", 604800), ("d", 86400), ("h", 3600), ("m", 60)):
        if seconds % size == 0 and seconds >= size:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


def format_time(epoch):
    return (
        dt.datetime.fromtimestamp(epoch).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    )


def ttl_choices(default_ttl, max_ttl):
    choices = {
        int(default_ttl),
        *(choice for choice in COMMON_TTL_CHOICES if choice <= max_ttl),
    }
    return sorted(choices)


def safe_name(value):
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._-")
    return safe or "target"


def targets_file_arg(value):
    if value:
        return expand_path(value)
    env_targets_file = os.environ.get(TARGETS_FILE_ENV)
    if env_targets_file:
        return expand_path(env_targets_file)
    return None


def env_flag(name):
    value = os.environ.get(name)
    if value is None:
        return None
    return value.strip().lower() in ("1", "true", "yes", "on")


def resolved_ca_key(args):
    ca_agent = args.ca_agent
    if ca_agent is None:
        ca_agent = args.ca_key is None
    ca_key = args.ca_key or (
        DEFAULT_CA_PUBLIC_KEY if ca_agent else DEFAULT_CA_PRIVATE_KEY
    )
    return ca_agent, expand_path(ca_key)


def load_targets_from_file(targets_file):
    try:
        targets = json.loads(targets_file.read_text(encoding="utf-8"))
    except OSError as exc:
        raise Error(f"failed to read targets file {targets_file}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise Error(f"failed to parse targets file {targets_file}: {exc}") from exc
    if not isinstance(targets, list) or not all(
        isinstance(target, dict) and isinstance(target.get("name"), str)
        for target in targets
    ):
        raise Error(f"targets file {targets_file} must contain a JSON list of targets")
    targets.sort(key=lambda item: item["name"])
    return targets


def load_targets(targets_file=None):
    targets_path = targets_file_arg(targets_file)
    if targets_path is None:
        raise Error(f"target metadata requires --targets-file or ${TARGETS_FILE_ENV}")
    return load_targets_from_file(targets_path)


def resolve_target(targets, requested, *, allow_disabled=False):
    exact = {target["name"]: target for target in targets}
    if requested in exact:
        target = exact[requested]
    else:
        matches = []
        for target in targets:
            aliases = set(target.get("aliases", []))
            if requested in aliases:
                matches.append(target)
        unique = {match["name"]: match for match in matches}
        if len(unique) > 1:
            names = ", ".join(sorted(unique))
            raise Error(f"ambiguous ticket target {requested!r}; matches: {names}")
        if not unique:
            known = ", ".join(
                target["name"] for target in targets if target.get("enabled")
            )
            raise Error(
                f"unknown ticket target {requested!r}; enabled targets: {known or '<none>'}"
            )
        target = next(iter(unique.values()))

    if not target.get("enabled") and not allow_disabled:
        raise Error(
            f"ticket target {target['name']} exists but host.sshTicket.enable is false"
        )
    return target


def display_target_name(target):
    return target["name"]


def target_paths(target, state_dir):
    base = state_dir / safe_name(target["name"])
    return {
        "public": pathlib.Path(f"{base}.pub"),
        "cert": pathlib.Path(f"{base}-cert.pub"),
        "metadata": pathlib.Path(f"{base}.json"),
    }


def ensure_ticket_key(key_path):
    public_path = pathlib.Path(f"{key_path}.pub")
    key_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not key_path.exists():
        run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "ssht ticket key",
                "-f",
                str(key_path),
            ],
            capture=False,
        )
    if not public_path.exists():
        public = run(["ssh-keygen", "-y", "-f", str(key_path)])
        public_path.write_text(public, encoding="utf-8")
    key_path.chmod(0o600)
    return public_path


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return None


def write_json(path, value):
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def existing_ticket_valid(target, paths):
    metadata = read_json(paths["metadata"])
    if metadata is None or not paths["cert"].exists():
        return False
    if metadata.get("target") != target["name"]:
        return False
    if metadata.get("principal") != target["principal"]:
        return False
    return int(metadata.get("validBefore", 0)) - int(time.time()) > MIN_VALID_SECONDS


def ticket_status(target, state_dir):
    paths = target_paths(target, state_dir)
    metadata = read_json(paths["metadata"])
    if metadata is None or not paths["cert"].exists():
        return {**target, "status": "missing"}
    valid_before = int(metadata.get("validBefore", 0))
    if valid_before - int(time.time()) <= MIN_VALID_SECONDS:
        return {**target, "status": "expired", "validBefore": valid_before}
    return {**target, "status": "valid", "validBefore": valid_before}


def prompt_tty(target, default_ttl, max_ttl, ttl_was_explicit):
    print(f"SSH ticket request for {target['name']}", file=sys.stderr)
    print(f"  principal: {target['principal']}", file=sys.stderr)
    print(f"  ssh host:  {target['sshHost']}", file=sys.stderr)
    if ttl_was_explicit:
        answer = input(f"Approve ticket for {format_duration(default_ttl)}? [y/N] ")
        if answer.strip().lower() not in ("y", "yes"):
            raise Error("ticket request denied")
        return default_ttl

    raw = input(
        f"TTL [{format_duration(default_ttl)}, max {format_duration(max_ttl)}; empty default, 'no' denies]: "
    ).strip()
    if raw.lower() in ("n", "no", "deny"):
        raise Error("ticket request denied")
    ttl = default_ttl if raw == "" else parse_duration(raw)
    answer = input(f"Approve ticket for {format_duration(ttl)}? [y/N] ")
    if answer.strip().lower() not in ("y", "yes"):
        raise Error("ticket request denied")
    return ttl


def prompt_askpass(target, default_ttl, max_ttl, ttl_was_explicit):
    askpass = os.environ.get("SSH_ASKPASS")
    if not askpass:
        return None
    if ttl_was_explicit:
        ttl = default_ttl
    else:
        prompt = (
            f"TTL for SSH ticket to {target['name']} "
            f"[{format_duration(default_ttl)}, max {format_duration(max_ttl)}]"
        )
        ttl_text = run([askpass, prompt]).strip()
        ttl = default_ttl if ttl_text == "" else parse_duration(ttl_text)
    answer = run(
        [
            askpass,
            f"Approve SSH ticket to {target['name']} for {format_duration(ttl)}? Type yes.",
        ]
    ).strip()
    if answer.lower() not in ("y", "yes"):
        raise Error("ticket request denied")
    return ttl


def prompt_osascript(target, default_ttl, max_ttl, ttl_was_explicit):
    osascript = shutil.which("osascript")
    if osascript is None:
        return None
    default_answer = format_duration(default_ttl)
    if ttl_was_explicit:
        message = (
            f"Approve SSH ticket for {target['name']}?\n\n"
            f"Principal: {target['principal']}\n"
            f"TTL: {default_answer}"
        )
        script = osascript_approval_script(message)
        result = subprocess.run(
            [osascript, "-e", script], text=True, capture_output=True
        )
        if result.returncode != 0 or result.stdout.strip() != "Approve":
            raise Error("ticket request denied")
        return default_ttl

    message = (
        f"Approve SSH ticket for {target['name']}?\n\n"
        f"Principal: {target['principal']}\n"
        f"Select TTL, max {format_duration(max_ttl)}."
    )
    choices = [format_duration(ttl) for ttl in ttl_choices(default_ttl, max_ttl)]
    script = osascript_ttl_selector_script(message, choices, default_answer)
    result = subprocess.run([osascript, "-e", script], text=True, capture_output=True)
    if result.returncode != 0:
        raise Error("ticket request denied")
    ttl_text = result.stdout.strip() or default_answer
    return default_ttl if ttl_text == "" else parse_duration(ttl_text)


def prompt_gui(target, default_ttl, max_ttl, ttl_was_explicit):
    ttl = prompt_askpass(target, default_ttl, max_ttl, ttl_was_explicit)
    if ttl is None:
        ttl = prompt_osascript(target, default_ttl, max_ttl, ttl_was_explicit)
    if ttl is None:
        raise Error("cannot prompt for approval without SSH_ASKPASS or osascript")
    return ttl


def approved_ttl(args, target):
    default_ttl = parse_duration(args.ttl or target["defaultTtl"])
    max_ttl = parse_duration(target["maxTtl"])
    ttl_was_explicit = args.ttl is not None
    if default_ttl > max_ttl:
        raise Error(
            f"requested TTL {format_duration(default_ttl)} exceeds max TTL {format_duration(max_ttl)} for {target['name']}"
        )
    if args.yes:
        return default_ttl
    if getattr(args, "gui", False):
        ttl = prompt_gui(target, default_ttl, max_ttl, ttl_was_explicit)
    elif sys.stdin.isatty():
        ttl = prompt_tty(target, default_ttl, max_ttl, ttl_was_explicit)
    else:
        ttl = prompt_gui(target, default_ttl, max_ttl, ttl_was_explicit)
    if ttl > max_ttl:
        raise Error(
            f"approved TTL {format_duration(ttl)} exceeds max TTL {format_duration(max_ttl)} for {target['name']}"
        )
    return ttl


def issue_ticket(args, target, state_dir, key_path):
    ttl = approved_ttl(args, target)
    public_key = ensure_ticket_key(key_path)
    paths = target_paths(target, state_dir)
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    public_text = public_key.read_text(encoding="utf-8")
    paths["public"].write_text(public_text, encoding="utf-8")
    paths["cert"].unlink(missing_ok=True)

    ca_agent, ca_key = resolved_ca_key(args)
    serial = int(time.time())
    identity = f"ssht:{target['name']}:{serial}"
    cmd = ["ssh-keygen", "-q"]
    if ca_agent:
        cmd.extend(["-U", "-s", str(ca_key)])
    else:
        cmd.extend(["-s", str(ca_key)])
    cmd.extend(
        [
            "-I",
            identity,
            "-n",
            target["principal"],
            "-O",
            "no-agent-forwarding",
            "-O",
            "no-x11-forwarding",
            "-V",
            f"-5m:+{ttl}s",
            "-z",
            str(serial),
            str(paths["public"]),
        ]
    )
    run(cmd, capture=False)

    now = int(time.time())
    metadata = {
        "target": target["name"],
        "sshHost": target["sshHost"],
        "principal": target["principal"],
        "identity": identity,
        "validAfter": now - 300,
        "validBefore": now + ttl,
        "issuedAt": now,
        "ttl": ttl,
        "certificateFile": str(paths["cert"]),
        "identityFile": str(key_path),
        "caAgent": ca_agent,
        "caKey": str(ca_key),
    }
    write_json(paths["metadata"], metadata)
    return paths


def ensure_ticket(args, target):
    state_dir = state_dir_arg(args)
    key_path = expand_path(args.key)
    paths = target_paths(target, state_dir)
    if not args.force and existing_ticket_valid(target, paths):
        return paths
    return issue_ticket(args, target, state_dir, key_path)


def write_ticket_alias(paths, alias, state_dir):
    alias_paths = target_paths({"name": alias}, state_dir)
    if alias_paths["cert"] == paths["cert"]:
        return alias_paths
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    for key in ("public", "cert", "metadata"):
        if paths[key].exists():
            alias_paths[key].write_text(
                paths[key].read_text(encoding="utf-8"), encoding="utf-8"
            )
    return alias_paths


def cmd_targets(args):
    targets = load_targets(args.targets_file)
    if not args.all:
        targets = [target for target in targets if target.get("enabled")]
    if args.json:
        print(json.dumps(targets, indent=2, sort_keys=True))
        return 0
    if not targets:
        print("No ticket targets.")
        return 0
    rows = [
        (
            display_target_name(target),
            "yes" if target.get("enabled") else "no",
            target["principal"],
            ",".join(target.get("aliases", [])),
            target["defaultTtl"],
            target["maxTtl"],
            "yes" if target.get("caPublicKeyConfigured") else "no",
        )
        for target in targets
    ]
    headers = ("target", "enabled", "principal", "aliases", "default", "max", "ca")
    widths = [len(header) for header in headers]
    for row in rows:
        widths = [max(width, len(value)) for width, value in zip(widths, row)]
    print("  ".join(header.ljust(width) for header, width in zip(headers, widths)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(value.ljust(width) for value, width in zip(row, widths)))
    return 0


def cmd_status(args):
    targets = load_targets(args.targets_file)
    state_dir = expand_path(args.state_dir) if args.state_dir else default_state_dir()
    if args.target:
        targets = [resolve_target(targets, args.target, allow_disabled=args.all)]
    elif not args.all:
        targets = [target for target in targets if target.get("enabled")]
    statuses = [ticket_status(target, state_dir) for target in targets]
    if args.json:
        print(json.dumps(statuses, indent=2, sort_keys=True))
        return 0
    for status in statuses:
        if status["status"] == "valid":
            detail = f"until {format_time(status['validBefore'])}"
        elif status["status"] == "expired" and status.get("validBefore"):
            detail = f"expired {format_time(status['validBefore'])}"
        else:
            detail = "missing"
        print(f"{display_target_name(status)}: {status['status']} ({detail})")
    return 0


def cmd_issue(args):
    targets = load_targets(args.targets_file)
    target = resolve_target(targets, args.target, allow_disabled=args.allow_disabled)
    state_dir = expand_path(args.state_dir) if args.state_dir else default_state_dir()
    paths = issue_ticket(args, target, state_dir, expand_path(args.key))
    print(str(paths["cert"]))
    return 0


def cmd_ensure(args):
    targets = load_targets(args.targets_file)
    target = resolve_target(targets, args.target, allow_disabled=args.allow_disabled)
    state_dir = state_dir_arg(args)
    paths = ensure_ticket(args, target)
    cert_alias = args.cert_alias or args.target
    alias_paths = write_ticket_alias(paths, cert_alias, state_dir)
    if not args.quiet:
        print(str(alias_paths["cert"]))
    return 0


def cmd_init_key(args):
    public_key = ensure_ticket_key(expand_path(args.key))
    print(str(public_key))
    return 0


def cmd_ssht(args):
    targets = load_targets(args.targets_file)
    target = resolve_target(targets, args.target, allow_disabled=args.allow_disabled)
    paths = ensure_ticket(args, target)
    cmd = ssht_ssh_command(args, target, paths)
    os.execvp("ssh", cmd)
    raise AssertionError("unreachable")


def ssht_ssh_command(args, target, paths):
    ssh_args = list(args.ssh_args)
    if ssh_args and ssh_args[0] == "--":
        ssh_args = ssh_args[1:]
    return [
        "ssh",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        f"IdentityFile={expand_path(args.key)}",
        "-o",
        f"CertificateFile={paths['cert']}",
        "-o",
        "ForwardAgent=no",
        "-o",
        "AddKeysToAgent=no",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
        target["sshHost"],
    ] + ssh_args


def add_target_source_options(parser):
    parser.add_argument(
        "--targets-file",
        help=f"JSON target metadata file; defaults to ${TARGETS_FILE_ENV} when set",
    )


def add_common_options(parser):
    add_target_source_options(parser)
    parser.add_argument(
        "--state-dir", help="directory for per-host certificates and metadata"
    )
    parser.add_argument(
        "--key",
        default=os.environ.get("SSHT_KEY", DEFAULT_KEY),
        help="ticket private key path",
    )
    parser.add_argument(
        "--ca-key",
        default=os.environ.get("SSHT_CA_KEY"),
        help="SSH user CA key path; defaults to ~/.ssh/fleet-user-ca.pub with agent signing",
    )
    ca_agent = parser.add_mutually_exclusive_group()
    ca_agent.add_argument(
        "--ca-agent",
        dest="ca_agent",
        action="store_true",
        help="sign with a CA key loaded in ssh-agent",
    )
    ca_agent.add_argument(
        "--no-ca-agent",
        dest="ca_agent",
        action="store_false",
        help="sign with a CA private key file",
    )
    parser.set_defaults(ca_agent=env_flag("SSHT_CA_AGENT"))
    parser.add_argument("--ttl", help="ticket lifetime, e.g. 30m, 2h, 1h30m")
    parser.add_argument(
        "--yes", action="store_true", help="issue without an approval prompt"
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        help="use SSH_ASKPASS or osascript instead of terminal input",
    )
    parser.add_argument(
        "--force", action="store_true", help="ignore an existing valid ticket"
    )
    parser.add_argument(
        "--allow-disabled",
        action="store_true",
        help="allow issuing for a target whose host.sshTicket.enable is false",
    )


def build_parser():
    parser = argparse.ArgumentParser(prog="ssh-ticket")
    subparsers = parser.add_subparsers(dest="command", required=True)

    targets = subparsers.add_parser(
        "targets", help="list configured SSH ticket targets"
    )
    add_target_source_options(targets)
    targets.add_argument("--all", action="store_true", help="include disabled targets")
    targets.add_argument("--json", action="store_true", help="emit JSON")
    targets.set_defaults(func=cmd_targets)

    status = subparsers.add_parser("status", help="show local ticket status")
    status.add_argument("target", nargs="?", help="target or alias")
    add_target_source_options(status)
    status.add_argument(
        "--state-dir", help="directory for per-host certificates and metadata"
    )
    status.add_argument("--all", action="store_true", help="include disabled targets")
    status.add_argument("--json", action="store_true", help="emit JSON")
    status.set_defaults(func=cmd_status)

    issue = subparsers.add_parser("issue", help="issue a ticket for one host")
    add_common_options(issue)
    issue.add_argument("target", help="target or alias")
    issue.set_defaults(func=cmd_issue)

    ensure = subparsers.add_parser(
        "ensure", help="issue or reuse a ticket without connecting"
    )
    add_common_options(ensure)
    ensure.add_argument("target", help="target or alias")
    ensure.add_argument(
        "--cert-alias",
        help="also write the certificate to this state-dir alias for ssh_config",
    )
    ensure.add_argument(
        "--quiet", action="store_true", help="do not print the cert path"
    )
    ensure.set_defaults(func=cmd_ensure)

    init_key = subparsers.add_parser(
        "init-key", help="create the reusable ticket keypair"
    )
    init_key.add_argument(
        "--key",
        default=os.environ.get("SSHT_KEY", DEFAULT_KEY),
        help="ticket private key path",
    )
    init_key.set_defaults(func=cmd_init_key)

    ssht = subparsers.add_parser(
        "ssht", help="connect to a host through a short-lived ticket"
    )
    add_common_options(ssht)
    ssht.add_argument("target", help="target or alias")
    ssht.add_argument(
        "ssh_args",
        nargs=argparse.REMAINDER,
        help="arguments passed after the resolved ssh host",
    )
    ssht.set_defaults(func=cmd_ssht)
    return parser


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Error as exc:
        print(f"ssh-ticket: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
