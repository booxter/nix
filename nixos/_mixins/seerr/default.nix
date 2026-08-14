{ lib, ... }:
{
  imports = [
    ./service.nix
    ./web.nix
  ];

  options.host.seerr = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options.stateDir = lib.mkOption {
          type = lib.types.strMatching "^/.*";
          default = "/var/lib/seerr";
        };
      }
    );
    default = null;
    description = "Seerr media request manager configuration.";
  };
}
