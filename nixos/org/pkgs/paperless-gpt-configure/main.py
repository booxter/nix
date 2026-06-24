import json
import os
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request


BASE_URL = os.environ["PAPERLESS_BASE_URL"].rstrip("/")
TOKEN = pathlib.Path(os.environ["PAPERLESS_API_TOKEN_FILE"]).read_text().strip()
AUTO_OCR_TAG = os.environ["PAPERLESS_GPT_AUTO_OCR_TAG"]
WORKFLOW_NAME = os.environ["PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME"]


def api(method, path, payload=None):
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=None if payload is None else json.dumps(payload).encode(),
        method=method,
        headers={
            "Accept": "application/json",
            "Authorization": f"Token {TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        raise RuntimeError(
            f"{method} {path} failed with HTTP {error.code}: {body}"
        ) from error
    return None if not body else json.loads(body)


def list_api(path, **params):
    query = urllib.parse.urlencode({"page_size": 100000, **params})
    response = api("GET", f"{path}?{query}")
    return response.get("results", response)


def wait_for_paperless():
    deadline = time.monotonic() + 120
    last_error = None
    while time.monotonic() < deadline:
        try:
            api("GET", "/api/status/")
            return
        except (OSError, RuntimeError) as error:
            last_error = error
            time.sleep(2)
    raise SystemExit(f"Timed out waiting for Paperless API: {last_error}")


def ensure_tag():
    matches = list_api("/api/tags/", name__iexact=AUTO_OCR_TAG)
    for tag in matches:
        if tag["name"].lower() == AUTO_OCR_TAG.lower():
            return tag

    return api(
        "POST",
        "/api/tags/",
        {
            "name": AUTO_OCR_TAG,
            "matching_algorithm": 0,
            "is_inbox_tag": False,
        },
    )


def workflow_payload(tag_id, workflow=None):
    trigger = {"type": 2}
    action = {"type": 1, "assign_tags": [tag_id]}

    if workflow and workflow.get("triggers"):
        trigger["id"] = workflow["triggers"][0]["id"]
    if workflow and workflow.get("actions"):
        action["id"] = workflow["actions"][0]["id"]

    return {
        "name": WORKFLOW_NAME,
        "order": 0,
        "enabled": True,
        "triggers": [trigger],
        "actions": [action],
    }


def ensure_workflow(tag):
    workflow = next(
        (
            workflow
            for workflow in list_api("/api/workflows/")
            if workflow["name"] == WORKFLOW_NAME
        ),
        None,
    )
    payload = workflow_payload(tag["id"], workflow)
    if workflow:
        api("PATCH", f"/api/workflows/{workflow['id']}/", payload)
    else:
        api("POST", "/api/workflows/", payload)


def main():
    wait_for_paperless()
    ensure_workflow(ensure_tag())


if __name__ == "__main__":
    main()
