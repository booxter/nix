{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.env;
  presetDefault = lib.mkOverride 900;
  graphical = pkgs.stdenv.hostPlatform.isDarwin || osConfig.host.desktop.enable;
in
{
  config = lib.mkIf (cfg.preset == "personal") (
    lib.mkMerge [
      {
        host.hm = presetDefault {
          fullName = "Ihar Hrachyshka";
          email = "ihar.hrachyshka@gmail.com";
        };
      }
      (lib.mkMerge [
        {
          host.hm.env = {
            sendEmail.transport = presetDefault "gmail";
            repositories.requests.preset = presetDefault [ "dotfiles" ];
          };
        }
        {
          host.hm = presetDefault {
            dev = {
              act.enable = true;
              codex = {
                enable = true;
                usage.warmer.enable = true;
              };
              go.enable = true;
            };
            podman.enable = true;
            ramalama.enable = true;
          };
        }
      ])
      (lib.mkIf graphical {
        host.hm = presetDefault {
          numberedWorkspaces = if pkgs.stdenv.hostPlatform.isDarwin then 4 else 6;
          firefox = {
            enable = true;
            search.provider = "degoog";
          };
          gmailctl = {
            enable = true;
            warmer.enable = true;
          };
          hyprland.enable = pkgs.stdenv.hostPlatform.isLinux;
          kitty.enable = true;
          matrix.enable = true;
          obsidian.enable = true;
          podman = {
            enable = true;
            desktop.enable = true;
          };
          spotify = {
            enable = true;
            spicetify.enable = true;
          };
          telegram.enable = true;
          thunderbird = {
            enable = true;
            account = {
              flavor = "gmail.com";
              imapAuthentication = "oauth2";
              smtp = {
                server = "smtp.gmail.com";
                authentication = "oauth2";
              };
            };
          };
          wireshark.enable = true;
        };
      })
    ]
  );
}
