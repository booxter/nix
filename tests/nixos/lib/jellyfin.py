# ruff: noqa: F821
# Included by Jellyfin VM tests; machine and token are supplied by the driver.
import json
import shlex


def api(path, method="GET", data=None):
    authorization = (
        'Authorization: MediaBrowser Client="Catalogue test", Device="VM", '
        'DeviceId="catalogue-test", Version="1"'
    )
    if token:
        authorization += f', Token="{token}"'
    command = [
        "curl",
        "--fail-with-body",
        "--silent",
        "--show-error",
        "--max-time",
        "30",
        "-X",
        method,
        "-H",
        authorization,
    ]
    if data is not None:
        command += ["-H", "Content-Type: application/json", "--data", json.dumps(data)]
    command += [f"http://127.0.0.1:8096/{path}"]
    output = machine.succeed(shlex.join(command))
    return json.loads(output) if output.strip() else None
