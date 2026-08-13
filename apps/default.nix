{
  inputs,
  outputs,
  pkgs,
  system,
}:
let
  inherit (pkgs) lib;
  commonArgs = {
    inherit
      inputs
      outputs
      pkgs
      system
      ;
  };
  specPaths =
    lib.mapAttrs'
      (fileName: _: lib.nameValuePair (lib.removeSuffix ".nix" fileName) (./specs + "/${fileName}"))
      (
        lib.filterAttrs (fileName: type: type == "regular" && lib.hasSuffix ".nix" fileName) (
          builtins.readDir ./specs
        )
      );
  appSpecs = lib.mapAttrs (
    name: path:
    let
      declaration = import path commonArgs;
      fields = builtins.attrNames declaration;
    in
    assert lib.assertMsg (builtins.isAttrs declaration) "app spec ${name} must return an attribute set";
    assert lib.assertMsg (
      fields == [
        "description"
        "package"
      ]
    ) "app spec ${name} must return exactly description and package";
    assert lib.assertMsg (lib.isDerivation declaration.package)
      "app spec ${name} package must be a derivation";
    assert lib.assertMsg (builtins.isString declaration.description)
      "app spec ${name} description must be a string";
    declaration // { program = "${declaration.package}/bin/${name}"; }
  ) specPaths;
  mkApp = _name: appSpec: {
    type = "app";
    inherit (appSpec) program;
    meta.description = appSpec.description;
  };
in
{
  apps = pkgs.lib.mapAttrs mkApp appSpecs;
  packages = pkgs.lib.mapAttrs (_: appSpec: appSpec.package) appSpecs;
}
