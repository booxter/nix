{
  hostPlatform,
  lib,
  ...
}:
let
  inherit (hostPlatform) isDarwin isLinux system;
in
{
  options.host = {
    platform = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Nix platform declared by the host inventory.";
    };

    isDarwin = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether the inventory platform uses the Darwin kernel.";
    };

    isLinux = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether the inventory platform uses the Linux kernel.";
    };
  };

  config = {
    assertions = [
      {
        assertion = isDarwin != isLinux;
        message = "Inventory platform ${system} must identify exactly one supported kernel.";
      }
    ];

    nixpkgs.hostPlatform = system;
    host = {
      platform = system;
      inherit isDarwin isLinux;
    };
  };
}
