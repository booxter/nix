{
  config,
  lib,
  pkgs,
  ...
}:

let
  installScript = lib.optionalString (config ? system) ''
    krew install krew
  '';

  isHomeManager = lib.hasAttr "hm" lib;
in
{
  config = lib.mkIf pkgs.stdenv.isDarwin (
    lib.optionalAttrs isHomeManager {
      home.activation.krewInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] installScript;
    }
    // lib.optionalAttrs (!isHomeManager) {
      system.activationScripts.applications.text = lib.mkForce installScript;
    }
  );
}
