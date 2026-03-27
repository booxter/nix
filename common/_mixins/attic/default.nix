{
  config,
  lib,
  pkgs,
  hostname,
  isWork,
  ...
}:
let
  hostSecretFile = ../../../secrets/${hostname}.yaml;
  hasHostSecretFile = builtins.pathExists hostSecretFile;
  # Keep work outputs out of the personal cache to preserve corporate isolation boundaries.
  manageAtticPushWithSops = !isWork && hasHostSecretFile;
  rootDir = if pkgs.stdenv.isDarwin then "/private/var/root" else "/root";
  atticConfigPath = "${rootDir}/.config/attic/config.toml";
in
lib.mkMerge [
  (lib.optionalAttrs manageAtticPushWithSops {
    nix.settings.post-build-hook = "${pkgs.writeShellScriptBin "attic-push-hook" ''
      if [[ -r "${atticConfigPath}" ]]; then
        ${pkgs.attic-client}/bin/attic push default $OUT_PATHS || true
      fi
    ''}/bin/attic-push-hook";
  })

  (lib.optionalAttrs hasHostSecretFile {
    sops = {
      defaultSopsFile = hostSecretFile;
    }
    // lib.optionalAttrs manageAtticPushWithSops {
      secrets = {
        "attic/token" = { };
      };
      templates."attic-client-config.toml" = {
        owner = "root";
        group = if pkgs.stdenv.isDarwin then "wheel" else "root";
        mode = "0400";
        content = ''
          default-server = "local"
          [servers.local]
          endpoint = "http://nix-cache:8080"
          token = "${config.sops.placeholder."attic/token"}"
        '';
      };
    };
  })

  (lib.optionalAttrs manageAtticPushWithSops {
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "${atticConfigPath}")"
      ${pkgs.coreutils}/bin/ln -sf ${
        config.sops.templates."attic-client-config.toml".path
      } "${atticConfigPath}"
    '';
  })
]
