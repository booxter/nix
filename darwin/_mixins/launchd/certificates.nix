# Local adaptation until the pinned inputs include these upstream changes:
# https://github.com/nix-community/home-manager/pull/10112
# https://github.com/nix-darwin/nix-darwin/pull/1881
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cacert = pkgs.cacert.override {
    blacklist = config.security.pki.caCertificateBlacklist;
  };
  certificateFile =
    config.environment.variables.NIX_SSL_CERT_FILE or "${cacert}/etc/ssl/certs/ca-bundle.crt";

  withCertificateEnvironment =
    serviceConfig:
    let
      args =
        if serviceConfig.ProgramArguments != null then
          serviceConfig.ProgramArguments
        else
          [ serviceConfig.Program ];
      program = if serviceConfig.Program != null then serviceConfig.Program else builtins.head args;
    in
    if serviceConfig.Program == null && serviceConfig.ProgramArguments == null then
      serviceConfig
    else
      serviceConfig
      // {
        # Let ProgramArguments select Bash. Home Manager otherwise prepends
        # Program to the arguments when adding its wait-for-store wrapper.
        Program = null;
        ProgramArguments = [
          # Use native Bash before the store is mounted; exec -a, type -P, and
          # positional argument slicing below require Bash features.
          "/bin/bash"
          "-c"
          ''
            if [ "''${NIX_SSL_CERT_FILE+x}" != x ] && [ "''${SSL_CERT_FILE+x}" != x ]; then
              export NIX_SSL_CERT_FILE=${lib.escapeShellArg certificateFile}
            fi
            ${lib.optionalString (!(lib.hasInfix "/" (toString program))) ''
              # Match the _PATH_STDPATH lookup documented in launchd.plist(5).
              set -- "$(PATH="$(/usr/bin/getconf PATH)" type -P -- "$1")" "''${@:2}"
            ''}
            exec -a "$0" "$@"
          ''
          (builtins.head args)
          program
        ]
        ++ builtins.tail args;
      };

  plists = lib.mapAttrs' (
    _: job:
    lib.nameValuePair "${job.serviceConfig.Label}.plist" {
      text = lib.mkForce (
        lib.generators.toPlist { escape = true; } (withCertificateEnvironment job.serviceConfig)
      );
    }
  );
in
{
  # Wrap the generated plists so lifecycle assertions and the service model
  # still inspect the original commands and their wait-for-store behavior.
  environment = {
    launchDaemons = plists config.launchd.daemons;
    launchAgents = plists config.launchd.agents;
    userLaunchAgents = plists config.launchd.user.agents;
  };

  home-manager.sharedModules = [
    {
      options.launchd.agents = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.config = lib.mkOption {
              apply = withCertificateEnvironment;
            };
          }
        );
      };
    }
  ];
}
