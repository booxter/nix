# ruff: noqa: F821
# The NixOS driver supplies machines and the constants declared in nr-remote.nix.

import json
import shlex


def as_reviewer(command):
    return f"su - reviewer -c {shlex.quote(command)}"


def remote(command):
    return server.succeed(as_reviewer(command)).strip()


def wait_remote(command):
    server.wait_until_succeeds(as_reviewer(command), timeout=30)


def report(pr):
    path = f"/home/reviewer/reviews/{pr}/report.json"
    server.wait_for_file(path)
    return json.loads(server.succeed(f"cat {path}"))


def windows():
    output = remote("tmux list-windows -t nr -F '#{window_name}'")
    return output.splitlines()


def attach():
    # A local tmux pane supplies the real terminal required by ssh -t.
    client.succeed(as_reviewer("tmux -L viewer new-session -d -s viewer -x 120 -y 40"))
    client.succeed(as_reviewer("tmux -L viewer send-keys 'nr -r --attach' Enter"))
    try:
        wait_remote("test \"$(tmux list-clients -t nr -F '#{client_session}')\" = nr")
    finally:
        print(client.succeed(as_reviewer("tmux -L viewer capture-pane -p")).strip())
    client.wait_until_succeeds(
        as_reviewer("tmux -L viewer capture-pane -p | grep -F 'review started'")
    )


start_all()
server.wait_for_unit("sshd.service")
client.wait_for_unit("multi-user.target")
client.succeed(as_reviewer("ssh server true"))
# Persist the freshly provisioned SSH key before simulating power loss.
client.succeed("sync")
remote(
    "mkdir -p ~/src/nixpkgs/nixos && cd ~/src/nixpkgs && "
    "touch nixos/release.nix && git init && git add . && "
    "git -c user.name=Test -c user.email=test@example.invalid commit -m Fixture"
)

with subtest("submission creates a detached remote session using server defaults"):
    output = client.succeed(as_reviewer("nr -r 123 -- -p llvmPackages_21.llvm"))
    assert "Submitted to server" in output, output
    first = report(123)
    assert first["builders"] == SERVER_BUILDERS, first
    assert "aarch64-linux" in first["systems"], first
    assert first["directory"] == "/home/reviewer/src/nixpkgs", first
    assert first["package"] == ["llvmPackages_21.llvm"], first
    assert not first["post_result"], first
    assert remote("tmux list-sessions -F '#{session_name}'") == "nr"
    first_windows = windows()
    assert len(first_windows) == 1, first_windows

with subtest("another submission reuses tmux without inheriting stale builder defaults"):
    remote("tmux set-environment -g NR_BUILDERS stale")
    remote("tmux set-environment -g NR_LOCAL_BUILDERS stale")
    client.succeed(as_reviewer("nr -r -l 124"))
    second = report(124)
    assert second["builders"] == SERVER_LOCAL_BUILDERS, second
    assert "aarch64-linux" not in second["systems"], second
    all_windows = windows()
    assert len(all_windows) == 2, all_windows
    assert set(first_windows) < set(all_windows), all_windows
    second_window = (set(all_windows) - set(first_windows)).pop()
    assert remote("tmux list-sessions -F '#{session_name}'") == "nr"
    assert remote("tmux list-panes -s -t nr -F '#{pane_dead}'").splitlines() == ["0", "0"]

with subtest("attach opens the existing session without submitting a job"):
    attach()
    assert windows() == all_windows

with subtest("reviews survive the client powering off while attached"):
    client.crash()
    wait_remote('test -z "$(tmux list-clients -t nr)"')
    assert remote("tmux list-panes -s -t nr -F '#{pane_dead}'").splitlines() == ["0", "0"]
    remote("touch ~/reviews/123/finish ~/reviews/124/finish")
    for window, status in ((first_windows[0], 0), (second_window, 7)):
        target = shlex.quote(f"nr:{window}")
        wait_remote(f"test \"$(tmux display-message -p -t {target} '#{{pane_dead}}')\" = 1")
        assert remote(f"tmux display-message -p -t {target} '#{{pane_dead_status}}'") == str(status)
        output = remote(f"tmux capture-pane -p -t {target}")
        assert f"nr: review finished (exit {status})" in output, output

with subtest("client reconnects to retained output and detaches cleanly"):
    client.start()
    client.wait_for_unit("multi-user.target")
    attach()
    assert windows() == all_windows
    client.succeed(as_reviewer("tmux -L viewer send-keys C-b d"))
    wait_remote('test -z "$(tmux list-clients -t nr)"')
    client.wait_until_succeeds(
        as_reviewer("tmux -L viewer capture-pane -p | grep -F '[detached (from session nr)]'")
    )
    assert windows() == all_windows
