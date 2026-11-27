# ruff: noqa: F821
# The NixOS test driver and Nix expressions supply globals.
def installed_versions():
    return {
        plugin["Version"]
        for plugin in api("Plugins")
        if plugin["Id"].replace("-", "") == PLUGIN_ID.replace("-", "")
    }


def switch_catalogue(path):
    machine.succeed(f"ln -sfn {shlex.quote(path)} /run/catalogue")


def run_updater():
    def task_info():
        return next(task for task in api("ScheduledTasks") if task["Key"] == "PluginUpdates")

    retry(lambda _: task_info()["State"] == "Idle")
    task = task_info()
    previous = (task.get("LastExecutionResult") or {}).get("EndTimeUtc")
    api(f"ScheduledTasks/Running/{task['Id']}", method="POST")

    def finished(_):
        current = task_info()
        result = current.get("LastExecutionResult") or {}
        return current["State"] == "Idle" and result.get("EndTimeUtc") != previous

    retry(finished)


def restart_and_check(version):
    machine.succeed("systemctl restart jellyfin.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/CatalogueFixture")
    state = api("CatalogueFixture")
    assert state["Version"] == version, state
    return state


machine.start()
machine.wait_for_unit("jellyfin.service")
machine.wait_for_unit("nginx.service")
token = ""

with subtest("fresh Jellyfin installs a Nix-built plugin through the catalogue"):
    switch_catalogue(ORIGINAL_CATALOGUE)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/Startup/FirstUser")
    api("Startup/FirstUser")
    api("Startup/Complete", method="POST")
    token = api("Users/AuthenticateByName", method="POST", data={"Username": "jellyfin"})[
        "AccessToken"
    ]
    machine.succeed(
        "printf '%s\\n' " + shlex.quote(f"JELLARR_API_KEY={token}") + " > /run/jellarr.env"
    )
    machine.succeed("systemctl start jellarr.service")
    assert ORIGINAL_VERSION in installed_versions()
    restart_and_check(ORIGINAL_VERSION)
    machine.succeed("systemctl start jellarr.service")
    api(
        f"Plugins/{PLUGIN_ID}/Configuration",
        method="POST",
        data={"ManagedSetting": "declarative", "UserSetting": "retained"},
    )

with subtest("a corrupt archive is rejected without replacing the installed plugin"):
    switch_catalogue(BAD_CHECKSUM_CATALOGUE)
    machine.succeed("journalctl --sync")
    cursor = json.loads(machine.succeed("journalctl -n 1 -o json"))["__CURSOR"]
    run_updater()
    checksum_log = machine.succeed(
        "journalctl -u jellyfin.service -o cat --after-cursor=" + shlex.quote(cursor)
    )
    assert "The checksums didn't match" in checksum_log, checksum_log
    assert installed_versions() == {ORIGINAL_VERSION}
    assert restart_and_check(ORIGINAL_VERSION)["UserSetting"] == "retained"

with subtest("an incompatible release is ignored"):
    switch_catalogue(INCOMPATIBLE_CATALOGUE)
    manifest = json.loads(machine.succeed("curl -fsS http://127.0.0.1:8181/manifest.json"))
    assert manifest[0]["versions"][0]["targetAbi"] == "99.0.0.0", manifest
    assert api("Packages") == []
    assert "99.0.0.0" not in installed_versions()
    run_updater()
    assert installed_versions() == {ORIGINAL_VERSION}

with subtest("the updater installs a higher local build and preserves configuration"):
    switch_catalogue(UPDATED_CATALOGUE)
    run_updater()
    assert UPDATED_VERSION in installed_versions()
    assert api("CatalogueFixture")["Version"] == ORIGINAL_VERSION
    state = restart_and_check(UPDATED_VERSION)
    assert state["ManagedSetting"] == "declarative", state
    assert state["UserSetting"] == "retained", state
    machine.succeed("systemctl start jellarr.service")
    assert restart_and_check(UPDATED_VERSION) == state

with subtest("an older catalogue does not downgrade the installed plugin"):
    switch_catalogue(ORIGINAL_CATALOGUE)
    run_updater()
    assert installed_versions() == {UPDATED_VERSION}
