from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"realms": {}, "groups": {}, "acls": {}}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise SystemExit("invalid fixture state")
    return value


def options(arguments: list[str]) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for index in range(0, len(arguments), 2):
        parsed[arguments[index]] = arguments[index + 1]
    return parsed


def main() -> None:
    state_path = Path(os.environ["PVEUM_STATE"])
    if os.environ.get("PVEUM_FAIL") == "1":
        print("fixture failure", file=sys.stderr)
        raise SystemExit(1)
    state = load_state(state_path)
    arguments = sys.argv[1:]

    if arguments == ["realm", "list", "--output-format", "json"]:
        if os.environ.get("PVEUM_INVALID_LIST") == "1":
            print("not-json")
            return
        print(json.dumps([{"realmid": name} for name in state["realms"]]))
        return
    if arguments == ["group", "list", "--output-format", "json"]:
        print(json.dumps([{"groupid": name} for name in state["groups"]]))
        return

    resource, operation = arguments[:2]
    if resource == "realm" and operation in {"add", "modify"}:
        name = arguments[2]
        state["realms"][name] = {"operation": operation} | options(arguments[3:])
    elif resource == "group" and operation == "add":
        name = arguments[2]
        state["groups"][name] = options(arguments[3:])
    elif resource == "aclmod":
        state["acls"][arguments[1]] = options(arguments[2:])
    else:
        raise SystemExit(f"unsupported fixture operation: {arguments}")
    state_path.write_text(json.dumps(state, sort_keys=True))


if __name__ == "__main__":
    main()
