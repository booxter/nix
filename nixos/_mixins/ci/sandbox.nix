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
    name: runner:
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
        # Registration must share the listener's root so DynamicUser state
        # mounts resolve consistently during preparation and job execution.
        MountAPIVFS = true;
        # '+' resolves these masks inside RootDirectory. The upstream masks
        # use host paths, which do not hide mounts inside the isolated root.
        InaccessiblePaths = [
          "+${runner.tokenFile}"
          "+/var/lib/github-runner/${name}/.current-token"
        ];

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
