{
  config,
  lib,
  ...
}:
let
  machines = config.host.nix.netrcMachines;
  machineType = lib.types.submodule {
    options = {
      login = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Optional login name for this netrc machine.";
      };
      password = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Password or bearer token for this netrc machine.";
      };
    };
  };
  renderMachine =
    name: machine:
    "machine ${name}"
    + lib.optionalString (machine.login != null) " login ${machine.login}"
    + " password ${machine.password}";
in
{
  options.host.nix.netrcMachines = lib.mkOption {
    type = lib.types.attrsOf machineType;
    default = { };
    internal = true;
    description = "Credentials made available to the Nix daemon through its netrc file.";
  };

  config = lib.mkIf (machines != { }) {
    nix.settings.netrc-file = config.sops.templates."nix-netrc".path;

    sops.templates."nix-netrc" = {
      owner = "root";
      # macOS names gid 0 "wheel"; there is no root group.
      group = if config.nixpkgs.hostPlatform.isDarwin then "wheel" else "root";
      mode = "0400";
      content = lib.concatLines (lib.mapAttrsToList renderMachine machines);
    };
  };
}
