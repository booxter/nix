{
  config,
  facts,
  isDarwin,
  isLinux,
  lib,
  ...
}:
let
  realmAttic = facts.realms.${config.host.realm}.services.attic or null;
in
{
  imports = [
    ./assertions.nix
    ./config.nix
  ]
  ++ lib.optionals isLinux [
    ./nixos-client.nix
    ./nixos-server.nix
  ]
  ++ lib.optional isDarwin ./darwin-client.nix;

  options.host.attic = {
    client = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = realmAttic != null;
        description = "Whether to upload new Nix store paths to the realm's Attic server.";
      };
    };

    server = {
      enable = lib.mkEnableOption "an Attic binary cache server";

      environmentFile = lib.mkOption {
        type = lib.types.str;
        default = "/etc/atticd.env";
        description = "Environment file containing the Attic server token secret.";
      };

      storagePath = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "/var/lib/atticd/storage";
        description = "Filesystem path used for Attic server storage.";
      };
    };
  };
}
