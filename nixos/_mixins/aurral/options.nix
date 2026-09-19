{
  lib,
  ...
}:
let
  absolutePath = lib.types.strMatching "^/.*";
  configType = lib.types.submodule {
    options = {
      stateDir = lib.mkOption {
        type = absolutePath;
        default = "/var/lib/aurral";
        description = "Persistent Aurral state directory.";
      };

      storageClaim = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Storage claim containing Aurral flows.";
      };

      libraryRoots = lib.mkOption {
        type = lib.types.listOf absolutePath;
        default = [ ];
        description = "Music library roots exposed read-only for local scanning and file reuse.";
      };

      publicHostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Public hostname published for Aurral.";
      };

    };
  };
in
{
  options.host.aurral = lib.mkOption {
    type = with lib.types; nullOr configType;
    default = null;
    description = "Aurral music discovery service.";
  };
}
