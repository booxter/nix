{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.host.hm.authRequest.package = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    internal = true;
    readOnly = true;
    default =
      if pkgs.stdenv.hostPlatform.isDarwin && config.host.hm.sketchybar.enable then
        pkgs.runCommand "auth-request-indicator"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            meta.mainProgram = "auth-request";
          }
          ''
            mkdir -p "$out/bin"
            makeWrapper ${lib.getExe pkgs.auth-request} "$out/bin/auth-request" \
              --add-flags ${
                lib.escapeShellArg (
                  lib.escapeShellArgs [
                    "--sketchybar"
                    (lib.getExe config.programs.sketchybar.package)
                    "--background"
                    "0xff${config.lib.stylix.colors.base0A}"
                    "--foreground"
                    "0xff${config.lib.stylix.colors.base00}"
                  ]
                )
              }
          ''
      else
        null;
    description = "Shared request indicator; callers supply a label and hold stdin open.";
  };
}
