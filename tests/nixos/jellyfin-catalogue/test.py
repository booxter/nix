# ruff: noqa: F821
# The NixOS test driver supplies machine, retry, and subtest.
def reconcile():
    machine.succeed("systemctl restart jellarr.service")
    configuration = api("System/Configuration")
    assert configuration["ServerName"] == "catalogue-test", configuration
    repositories = configuration["PluginRepositories"]
    assert {repository["Name"] for repository in repositories} == {
        "Local builds",
        "Existing repository",
    }, repositories
    assert all(repository["Enabled"] for repository in repositories), repositories
    assert api("Packages") == []


machine.start()
machine.wait_for_unit("jellyfin.service")
machine.wait_for_unit("nginx.service")
token = ""

with subtest("catalogue serves JSON only on loopback"):
    assert json.loads(machine.succeed("curl -fsS http://127.0.0.1:8181/manifest.json")) == []
    listeners = machine.succeed("ss -H -ltn 'sport = :8181'").splitlines()
    assert len(listeners) == 1 and "127.0.0.1:8181" in listeners[0], listeners
    machine.fail(
        "curl --noproxy '*' -fsS --connect-timeout 2 http://192.168.1.1:8181/manifest.json"
    )

with subtest("Jellarr registers the empty catalogue alongside existing repositories"):
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/Startup/FirstUser")
    api("Startup/FirstUser")
    api("Startup/Complete", method="POST")
    session = api("Users/AuthenticateByName", method="POST", data={"Username": "jellyfin"})
    token = session["AccessToken"]
    machine.succeed(
        "printf '%s\\n' " + shlex.quote(f"JELLARR_API_KEY={token}") + " > /run/jellarr.env"
    )
    reconcile()
    reconcile()

with subtest("one reconciliation replaces a larger existing repository list"):
    configuration = api("System/Configuration")
    configuration["EnableMetrics"] = True
    configuration["PluginRepositories"] = [
        {
            "Name": f"Old repository {index}",
            "Url": f"http://127.0.0.1:8181/existing.json?old={index}",
            "Enabled": True,
        }
        for index in range(6)
    ]
    api("System/Configuration", method="POST", data=configuration)
    reconcile()
    assert api("System/Configuration")["EnableMetrics"] is True
    reconcile()

with subtest("registration survives restarting Jellyfin and nginx"):
    machine.succeed("systemctl restart nginx.service jellyfin.service")
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
    reconcile()
