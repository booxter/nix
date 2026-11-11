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
