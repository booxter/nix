{ pkgs }:
let
  fixtures = pkgs.runCommand "hardware-signing-fixtures" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p "$out"
    for name in local forwarded unapproved; do
      ssh-keygen -q -t ed25519 -N "" -C "$name" -f "$out/$name"
    done
    cat "$out/local.pub" "$out/forwarded.pub" > "$out/approved"
  '';
  selectKey = pkgs.callPackage ../../hm/_mixins/ssh/pkgs/git-hardware-signing-key.nix {
    approvedKeysFile = "${fixtures}/approved";
    localIdentityFile = "local-key";
  };
in
pkgs.runCommand "hardware-signing"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.openssh
    ];
    __darwinAllowLocalNetworking = true;
  }
  ''
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
    export SSH_AUTH_SOCK="$TMPDIR/agent.sock"
    eval "$(ssh-agent -a "$SSH_AUTH_SOCK")"
    trap 'ssh-agent -k >/dev/null' EXIT

    git init repo
    cd repo
    git config user.name Operator
    git config user.email operator@example.test
    git config gpg.format ssh
    git config commit.gpgSign true
    git config gpg.ssh.defaultKeyCommand ${selectKey}/bin/git-hardware-signing-key
    git config gpg.ssh.allowedSignersFile "$PWD/allowed-signers"
    install -m 600 ${fixtures}/local local-key
    install -m 600 ${fixtures}/forwarded forwarded-key
    install -m 600 ${fixtures}/unapproved unapproved-key
    printf 'operator@example.test %s\n' "$(cat ${fixtures}/local.pub)" > allowed-signers
    printf 'operator@example.test %s\n' "$(cat ${fixtures}/forwarded.pub)" >> allowed-signers

    # Local sessions can load the configured hardware handle into their agent.
    unset SSH_CONNECTION
    git commit --allow-empty -m local
    git verify-commit HEAD

    # Remote signing uses the originating key, even with other agent identities.
    ssh-add -D
    ssh-add unapproved-key forwarded-key
    export SSH_CONNECTION='client 1234 server 22'
    git commit --allow-empty -m forwarded
    printf 'operator@example.test %s\n' "$(cat ${fixtures}/forwarded.pub)" > allowed-signers
    git verify-commit HEAD

    # Neither a software-only agent nor no agent may trigger a local fallback.
    ssh-add -D
    ssh-add unapproved-key
    if git commit --allow-empty -m rejected-software; then
      echo 'Signing unexpectedly accepted an unapproved key' >&2
      exit 1
    fi
    ssh-add -D
    if git commit --allow-empty -m rejected-empty; then
      echo 'Remote signing unexpectedly loaded the local key' >&2
      exit 1
    fi
    unset SSH_AUTH_SOCK
    if git commit --allow-empty -m rejected-no-agent; then
      echo 'Signing unexpectedly succeeded without an agent' >&2
      exit 1
    fi
    touch "$out"
  ''
