{ pkgs }:
pkgs.runCommand "sudo-agent-darwin"
  {
    # pam_start reads native policy locations before creating an Apple handle.
    sandboxProfile = ''
      (allow file-read*
        (subpath "/private/etc/pam.d")
        (literal "/private/etc/pam.conf")
        (subpath "/private/var/db/ManagedConfigurationFiles/com.apple.pam")
        (subpath "/usr/lib/pam"))
    '';
    nativeBuildInputs = [
      pkgs.stdenv.cc
      pkgs.openssh
    ];
  }
  ''
    # Use Apple's PAM, as /usr/bin/sudo does. Never install a PAM policy or
    # authenticate through the host's real sudo stack during this test.
    cc -Wall -Werror -I${pkgs.openpam}/include ${./probe.c} -o probe
    agent_environment=$(ssh-agent -a "$TMPDIR/agent.sock" -s)
    eval "$agent_environment"
    trap 'ssh-agent -k' EXIT

    ssh-keygen -q -t ecdsa -b 256 -N "" -f approved
    ssh-keygen -q -t ed25519 -N "" -f unapproved
    cp approved.pub operator.pub

    module=${pkgs.pam_rssh}/lib/libpam_rssh.dylib
    allowlist="auth_key_file=$PWD/\$ruser.pub"

    ssh-add approved
    ./probe "$module" "$allowlist" allow

    ssh-add -D
    ssh-add unapproved
    ./probe "$module" "$allowlist" deny
    ./probe "$module" "auth_key_file=$PWD/missing.pub" deny

    ssh-add -D
    ./probe "$module" "$allowlist" deny
    env -u SSH_AUTH_SOCK ./probe "$module" "$allowlist" deny

    touch "$out"
  ''
