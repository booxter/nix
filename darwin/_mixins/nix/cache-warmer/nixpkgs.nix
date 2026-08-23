{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.cacheWarmer.nixpkgs;
  installables = lib.concatMap (
    branch:
    lib.concatMap (
      system:
      map (package: "github:NixOS/nixpkgs/${branch}#legacyPackages.${system}.${package}") cfg.packages
    ) cfg.systems
  ) cfg.branches;
  arguments = [
    (lib.getExe pkgs.nix)
    "build"
    "-L"
    "--keep-going"
    "--max-jobs"
    "1"
    "--no-link"
    "--refresh"
  ]
  ++ installables;
in
{
  options.host.nix.cacheWarmer.nixpkgs = {
    enable = lib.mkEnableOption "periodic nixpkgs cache warming";

    branches = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Nixpkgs branches to warm.";
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Nixpkgs package attribute paths to warm.";
    };

    systems = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Nix systems to warm for every branch.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.branches != [ ];
        message = "host.nix.cacheWarmer.nixpkgs.branches must not be empty";
      }
      {
        assertion = cfg.packages != [ ];
        message = "host.nix.cacheWarmer.nixpkgs.packages must not be empty";
      }
      {
        assertion = cfg.systems != [ ];
        message = "host.nix.cacheWarmer.nixpkgs.systems must not be empty";
      }
      {
        assertion = config.host.attic.realmServers != { };
        message = "nixpkgs cache warming requires at least one Attic cache";
      }
    ];

    launchd.daemons.nixpkgs-cache-warmer = {
      command = lib.escapeShellArgs arguments;
      serviceConfig = {
        StartCalendarInterval = lib.genList (index: {
          Hour = index * 4;
          Minute = 0;
        }) 6;
        WorkingDirectory = "/var/root";
        EnvironmentVariables = {
          HOME = "/var/root";
          NIX_CONFIG = "builders = ${config.host.nix.cacheWarmer.builders}";
          NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        };
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-darwin/nixpkgs-cache-warmer.log";
        StandardErrorPath = "/var/log/nix-darwin/nixpkgs-cache-warmer.log";
      };
    };
  };
}
