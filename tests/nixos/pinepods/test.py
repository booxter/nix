# ruff: noqa: F821
# NixOS test-driver globals and Nix-generated constants are prepended at evaluation.

import json
import shlex

start_all()
ollama.wait_for_unit("nginx.service")
machine.wait_for_unit("postgresql.service")
machine.wait_for_unit("pinepods-valkey.service")
machine.wait_for_unit("podman-pinepods.service")
machine.succeed(f"curl -sf http://127.0.0.1:8040/api/health | {JQ} -e '.database and .redis'")
machine.wait_for_unit("pinepods-bootstrap-admin.service")
machine.succeed(
    "curl -sf http://127.0.0.1:8040/api/data/self_service_status"
    f" | {JQ} -e '.first_admin_created == true'"
)
machine.succeed("runuser -u pinepods -- test -w /srv/podcasts/podcasts/pinepods")

machine.wait_for_unit("pinepods-ai-settings.service")
login = json.loads(
    machine.succeed(
        "curl -sS --fail-with-body -u owner:test-password http://127.0.0.1:8040/api/data/get_key"
    )
)
api = "curl -sf -H " + shlex.quote("Api-Key: " + login["retrieved_key"])
base = "http://127.0.0.1:8040/api/data"
machine.wait_until_succeeds(
    f"{api} {base}/ai_status | {JQ} -e '.available and .transcription_ready and .ad_removal_ready'"
)
settings = json.loads(machine.succeed(f"{api} {base}/ai_settings"))["settings"]
assert settings["llm_backend"] == "remote", settings
assert settings["llm_model"] == "test-model", settings
assert not settings["has_api_key"], settings

models = json.loads(
    machine.succeed(
        f"{api} --get --data-urlencode "
        + shlex.quote("remote_url=" + settings["llm_url"])
        + f" {base}/ai_models"
    )
)
assert models["models"]["llm_remote"] == ["test-model"], models

# Rotating the tunnel's certificate must not stop the transcription service.
machine.succeed("systemctl restart stunnel.service")
machine.succeed("systemctl is-active podman-pinepods-ai.service")

machine.succeed(
    f"sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d pinepods -f {SUBSCRIPTIONS_FIXTURE}"
)
user_id = login["user_id"]


def check_subscription(podcast_id: int) -> None:
    query = f"user_id={user_id}&podcast_id={podcast_id}"
    for setting in ("auto_transcribe", "auto_ad_detect", "ad_skip_auto_activate"):
        result = json.loads(machine.succeed(f"{api} '{base}/get_{setting}?{query}'"))
        assert result["enabled"], (podcast_id, setting, result)

    payload = json.dumps({"user_id": user_id, "podcast_id": podcast_id})
    result = json.loads(
        machine.succeed(
            f"{api} -H 'Content-Type: application/json' -d {shlex.quote(payload)}"
            f" {base}/get_auto_download_status"
        )
    )
    assert result["auto_download"], (podcast_id, result)


machine.succeed("systemctl start pinepods-subscriptions.service")
check_subscription(101)

# A later run picks up newly added subscriptions and repairs manual opt-outs.
machine.succeed(
    "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d pinepods -c "
    + shlex.quote(
        'INSERT INTO "Podcasts" (podcastid, podcastname, feedurl, userid, adskipautoactivate) '
        "SELECT 103, 'Later subscription', 'https://example.invalid/later.xml', userid, false "
        "FROM \"Users\" WHERE username = 'owner';"
    )
)
payload = json.dumps({"user_id": user_id, "podcast_id": 101, "enabled": False})
machine.succeed(
    f"{api} -H 'Content-Type: application/json' -d {shlex.quote(payload)}"
    f" {base}/adjust_ad_skip_auto_activate"
)
machine.succeed("systemctl start pinepods-subscriptions.service")
check_subscription(101)
check_subscription(103)

other_settings = machine.succeed(
    "sudo -u postgres psql -X -A -t -d pinepods -c "
    + shlex.quote(
        "SELECT autodownload OR autotranscribe OR autoaddetect OR adskipautoactivate "
        'FROM "Podcasts" WHERE podcastid = 102;'
    )
).strip()
assert other_settings == "f", other_settings
machine.succeed("systemctl start pinepods-subscriptions.timer")
machine.succeed("systemctl is-active pinepods-subscriptions.timer")
