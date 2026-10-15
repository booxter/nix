# ruff: noqa: F821
# The NixOS test driver supplies the controller and target machines.

import shlex


def as_deployer(command):
    return f"su - deployer -c {shlex.quote(command)}"


def tmux(command):
    return controller.succeed(as_deployer(f"tmux -L deploy-smoke {command}")).strip()


start_all()
controller.wait_for_unit("multi-user.target")
target.wait_for_unit("sshd.service")
controller.succeed(as_deployer("ssh target true"))

controller_system = controller.succeed("readlink -f /run/current-system").strip()
target_system = target.succeed("readlink -f /run/current-system").strip()
deployed_system = target.succeed("readlink -f /run/current-system/specialisation/deployed").strip()
assert controller.succeed("cat /etc/deploy-smoke").strip() == "before"
assert target.succeed("cat /etc/deploy-smoke").strip() == "before"

controller.succeed(
    "cp -LR /etc/deploy-source /home/deployer/source && "
    "chown -R deployer:users /home/deployer/source && "
    "chmod -R u+w /home/deployer/source"
)
controller.succeed(
    as_deployer(
        "cd ~/source && git init && git add . && "
        "git -c user.name=Test -c user.email=test@example.invalid commit -m Fixture"
    )
)

with subtest("deploy switches the remote target and leaves the controller unchanged"):
    # Keep the real terminal and its output after deploy exits, including on failure.
    tmux("new-session -d -s deploy")
    tmux("set-window-option -t deploy remain-on-exit on")
    command = "cd ~/source && deploy --local --no-merge target"
    tmux(f"respawn-pane -k -t deploy {shlex.quote(command)}")
    try:
        controller.wait_until_succeeds(
            as_deployer(
                "test \"$(tmux -L deploy-smoke display-message -p -t deploy '#{pane_dead}')\" = 1"
            ),
            timeout=180,
        )
    finally:
        print(tmux("capture-pane -p -S - -t deploy"))
    assert tmux("display-message -p -t deploy '#{pane_dead_status}'") == "0"

    assert target.succeed("cat /etc/deploy-smoke").strip() == "after"
    assert target.succeed("readlink -f /run/current-system").strip() == deployed_system
    assert target.succeed("readlink -f /nix/var/nix/profiles/system").strip() == deployed_system
    assert deployed_system != target_system
    assert controller.succeed("readlink -f /run/current-system").strip() == controller_system
    assert controller.succeed("cat /etc/deploy-smoke").strip() == "before"
    controller.succeed(as_deployer("ssh target true"))
