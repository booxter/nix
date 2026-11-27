# ruff: noqa: F821
# The NixOS driver and shared Jellyfin API helper supply globals.


def assert_plugins_active():
    plugins = {plugin["Id"].replace("-", ""): plugin for plugin in api("Plugins")}
    for plugin_id, version in EXPECTED.items():
        assert plugin_id in plugins, plugins
        plugin = plugins[plugin_id]
        assert plugin["Version"] == version, plugin
        assert plugin["Status"] == "Active", plugin


machine.start()
machine.wait_for_unit("jellyfin.service")
machine.wait_for_unit("nginx.service")
machine.wait_for_unit("meilisearch.service")
token = ""

with subtest("a fresh server installs every external plugin from our catalogue"):
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
    packages = api("Packages")
    assert {package["guid"].replace("-", "") for package in packages} == set(EXPECTED), packages
    assert all(
        version["sourceUrl"].startswith("http://127.0.0.1:8181/")
        for package in packages
        for version in package["versions"]
    ), packages

with subtest("all rebuilt plugins load together and remain active after reconciliation"):
    machine.succeed("systemctl restart jellyfin.service")
    machine.wait_until_succeeds(
        shlex.join(
            [
                "curl",
                "-fsS",
                "-H",
                f'Authorization: MediaBrowser Token="{token}"',
                "http://127.0.0.1:8096/Plugins",
            ]
        )
    )
    assert_plugins_active()
    machine.succeed("systemctl start jellarr.service")
    assert_plugins_active()
