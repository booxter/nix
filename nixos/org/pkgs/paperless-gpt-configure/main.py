import json
import os
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request


BASE_URL = os.environ["PAPERLESS_BASE_URL"].rstrip("/")
TOKEN = pathlib.Path(os.environ["PAPERLESS_API_TOKEN_FILE"]).read_text().strip()
AUTO_TAG = os.environ["PAPERLESS_GPT_AUTO_TAG"]
AUTO_TAG_COMPLETE = os.environ["PAPERLESS_GPT_AUTO_TAG_COMPLETE"]
AUTO_OCR_TAG = os.environ["PAPERLESS_GPT_AUTO_OCR_TAG"]
OCR_COMPLETE_TAG = os.environ["PAPERLESS_GPT_OCR_COMPLETE_TAG"]
AUTO_OCR_WORKFLOW_NAME = os.environ["PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME"]
POST_OCR_WORKFLOW_NAME = os.environ["PAPERLESS_GPT_POST_OCR_WORKFLOW_NAME"]


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


def ensure_tag(name):
    matches = list_api("/api/tags/", name__iexact=name)
    for tag in matches:
        if tag["name"].lower() == name.lower():
            return tag

    return api(
        "POST",
        "/api/tags/",
        {
            "name": name,
            "matching_algorithm": 0,
            "is_inbox_tag": False,
        },
    )


def preserve_ids(items, existing_items):
    for index, item in enumerate(items):
        if index < len(existing_items) and "id" in existing_items[index]:
            item["id"] = existing_items[index]["id"]
    return items


def workflow_payload(name, triggers, actions, workflow=None):
    workflow = workflow or {}

    return {
        "name": name,
        "order": 0,
        "enabled": True,
        "triggers": preserve_ids(triggers, workflow.get("triggers", [])),
        "actions": preserve_ids(actions, workflow.get("actions", [])),
    }


def desired_workflows(tags):
    return [
        (
            AUTO_OCR_WORKFLOW_NAME,
            [{"type": 2}],
            [{"type": 1, "assign_tags": [tags[AUTO_OCR_TAG]["id"]]}],
        ),
        (
            POST_OCR_WORKFLOW_NAME,
            [
                {
                    "type": 3,
                    "filter_has_tags": [tags[OCR_COMPLETE_TAG]["id"]],
                    "filter_has_not_tags": [
                        tags[AUTO_TAG]["id"],
                        tags[AUTO_TAG_COMPLETE]["id"],
                    ],
                }
            ],
            [{"type": 1, "assign_tags": [tags[AUTO_TAG]["id"]]}],
        ),
    ]


def ensure_workflow(name, triggers, actions):
    workflow = next(
        (
            workflow
            for workflow in list_api("/api/workflows/")
            if workflow["name"] == name
        ),
        None,
    )
    payload = workflow_payload(name, triggers, actions, workflow)
    if workflow:
        api("PATCH", f"/api/workflows/{workflow['id']}/", payload)
    else:
        api("POST", "/api/workflows/", payload)


def main():
    wait_for_paperless()
    tags = {
        name: ensure_tag(name)
        for name in [AUTO_TAG, AUTO_TAG_COMPLETE, AUTO_OCR_TAG, OCR_COMPLETE_TAG]
    }
    for name, triggers, actions in desired_workflows(tags):
        ensure_workflow(name, triggers, actions)


if __name__ == "__main__":
    main()
