#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from collections import Counter


SCHEMA_VERSION = 1


class InboxError(RuntimeError):
    pass


def fetch_gitlab_todos(hostname=None, *, runner=subprocess.run):
    command = [
        "glab",
        "api",
        "todos?state=pending&per_page=100",
        "--paginate",
        "--output",
        "ndjson",
    ]
    if hostname:
        command.extend(["--hostname", hostname])

    try:
        result = runner(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as error:
        raise InboxError("glab is not installed or is not available on PATH") from error

    if result.returncode != 0:
        detail = result.stderr.strip()
        message = f"glab exited with status {result.returncode}"
        if detail:
            message += f": {detail}"
        raise InboxError(message)

    return parse_json_records(result.stdout)


def parse_json_records(output):
    records = []
    for line_number, line in enumerate(output.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise InboxError(
                f"glab returned invalid JSON on output line {line_number}"
            ) from error

        if isinstance(value, dict):
            records.append(value)
        elif isinstance(value, list) and all(
            isinstance(record, dict) for record in value
        ):
            records.extend(value)
        else:
            raise InboxError(
                f"glab returned an unexpected JSON value on output line {line_number}"
            )
    return records


def snake_case(value):
    value = str(value or "item").replace("::", "_")
    value = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", value)
    return re.sub(r"[^a-zA-Z0-9]+", "_", value).strip("_").lower() or "item"


def first_text(*values):
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def normalize_timestamp(value):
    value = first_text(value)
    if value is None:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    if parsed.tzinfo is None:
        return value
    return parsed.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def item_reference(kind, target):
    iid = target.get("iid")
    if iid is None:
        return None
    prefix = {
        "issue": "#",
        "merge_request": "!",
    }.get(kind, "")
    return f"{prefix}{iid}"


def normalize_gitlab_todo(todo):
    source_id = todo.get("id")
    if source_id is None:
        raise InboxError("GitLab returned a to-do item without an id")

    target = todo.get("target") if isinstance(todo.get("target"), dict) else {}
    project = todo.get("project") if isinstance(todo.get("project"), dict) else {}
    author = todo.get("author") if isinstance(todo.get("author"), dict) else {}
    kind = snake_case(todo.get("target_type"))
    title = (
        first_text(
            target.get("title"),
            target.get("name"),
            todo.get("body"),
            todo.get("target_type"),
        )
        or "Untitled item"
    )

    return {
        "id": f"gitlab:{source_id}",
        "source": "gitlab",
        "source_id": source_id,
        "kind": kind,
        "reason": snake_case(todo.get("action_name")),
        "context": first_text(
            project.get("path_with_namespace"),
            project.get("name_with_namespace"),
            project.get("name"),
        ),
        "reference": item_reference(kind, target),
        "title": title,
        "body": first_text(todo.get("body")),
        "url": first_text(todo.get("target_url")),
        "author": {
            "name": first_text(author.get("name")),
            "username": first_text(author.get("username")),
        },
        "created_at": normalize_timestamp(todo.get("created_at")),
        "updated_at": normalize_timestamp(todo.get("updated_at")),
    }


def collect_inbox(*, hostname=None, fetcher=fetch_gitlab_todos):
    items = [normalize_gitlab_todo(todo) for todo in fetcher(hostname)]
    return sorted(
        items,
        key=lambda item: item["updated_at"] or item["created_at"] or "",
        reverse=True,
    )


def build_document(items):
    counts = Counter(item["source"] for item in items)
    return {
        "schema_version": SCHEMA_VERSION,
        "summary": {
            "total": len(items),
            "by_source": dict(sorted(counts.items())),
        },
        "items": items,
    }


def reason_label(reason):
    labels = {
        "approval_required": "Approval required",
        "assigned": "Assigned",
        "build_failed": "Build failed",
        "directly_addressed": "Directly addressed",
        "marked": "Marked",
        "member_access_requested": "Member access requested",
        "mentioned": "Mentioned",
        "merge_train_removed": "Removed from merge train",
        "unmergeable": "Unmergeable",
    }
    return labels.get(reason, reason.replace("_", " ").capitalize())


def render_text(items):
    if not items:
        return "No pending items.\n"

    noun = "item" if len(items) == 1 else "items"
    lines = [f"{len(items)} pending {noun}:"]
    for item in items:
        location = item["context"] or ""
        if item["reference"]:
            location += item["reference"]
        fields = [
            f"[{item['source']}] {reason_label(item['reason'])}",
            location or None,
            item["title"],
        ]
        lines.append("- " + " · ".join(field for field in fields if field))
        if item["url"]:
            lines.append(f"  {item['url']}")
    return "\n".join(lines) + "\n"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Show pending attention items collected from external services."
    )
    parser.add_argument(
        "--format",
        type=str.lower,
        choices=("text", "json"),
        default="text",
        help="output format (default: text)",
    )
    parser.add_argument(
        "--gitlab-hostname",
        metavar="HOST",
        help="GitLab hostname passed to glab (default: glab context)",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        items = collect_inbox(hostname=args.gitlab_hostname)
    except InboxError as error:
        print(f"attention-inbox: {error}", file=sys.stderr)
        return 1

    if args.format == "json":
        print(json.dumps(build_document(items), indent=2))
    else:
        sys.stdout.write(render_text(items))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
