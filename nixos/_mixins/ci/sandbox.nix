{
  config,
  lib,
  pkgs,
  ...
}:
let
  runners = lib.filterAttrs (_: runner: runner.enable) config.services.github-runners;
  root = name: "/run/github-runner-roots/${name}";
in
{
  systemd.tmpfiles.rules = lib.mapAttrsToList (name: _: "d ${root name} 0755 root root -") runners;

  systemd.services = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "github-runner-${name}" {
      after = [
        "systemd-tmpfiles-setup.service"
        "nix-daemon.socket"
        "nscd.service"
      ];
      requires = [
        "nix-daemon.socket"
        "nscd.service"
      ];
      serviceConfig = {
        RootDirectory = root name;
        # The upstream registration scripts prepare tokens and clean state on
        # the host. Only the listener (and all of its job children) enters the root.
        RootDirectoryStartOnly = true;
        # Pre-start commands resolve WorkingDirectory below RootDirectory even
        # without entering it. Their scripts use absolute paths; the packaged
        # listener changes directory itself and uses RUNNER_ROOT for its state.
        WorkingDirectory = lib.mkForce "/";
        MountAPIVFS = true;

        # State/Runtime/Logs/CacheDirectory and LoadCredential are mounted by
        # systemd. Never expose host homes, /run/secrets, or the rest of /run.
        BindReadOnlyPaths = [
          "/nix/store"
          "/nix/var/nix/daemon-socket"
          "/etc/nix/nix.conf"
          "/etc/nix/registry.json"
          "/etc/hosts"
          "/etc/resolv.conf"
          "/etc/nsswitch.conf"
          "/etc/passwd"
          "/etc/group"
          "/etc/ssl/certs/ca-certificates.crt"
          # glibc looks under /var/run, which is not a symlink in this root.
          # NSS supplies the dynamic runner identity and host name resolution.
          "/run/nscd:/var/run/nscd"
          "${pkgs.bash}/bin/bash:/bin/sh"
          "${pkgs.coreutils}/bin/env:/usr/bin/env"
        ];
      };
    }
  ) runners;
}
