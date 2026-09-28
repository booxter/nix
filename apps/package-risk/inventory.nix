let
  flakeRef = builtins.getEnv "PACKAGE_RISK_FLAKE_REF";
  flake = builtins.getFlake flakeRef;
  configurations =
    kind: values:
    builtins.map (name: {
      inherit kind name;
      system = values.${name}.pkgs.stdenv.hostPlatform.system;
    }) (builtins.attrNames values);
in
configurations "nixos" (flake.nixosConfigurations or { })
++ configurations "darwin" (flake.darwinConfigurations or { })
