{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  username = config.host.username;
  presetDefault = lib.mkOverride 900;
  graphical = config.nixpkgs.hostPlatform.isDarwin || config.host.desktop.enable;
in
{
  config = lib.mkIf (cfg.preset == "personal") (
    lib.mkMerge [
      {
        home-manager.users.${username}.host.hm = presetDefault {
          fullName = "Ihar Hrachyshka";
          email = "ihar.hrachyshka@gmail.com";
        };
      }
      (lib.mkIf cfg.roles.developer.enable {
        host.userEnvironment = {
          sendEmail.transport = presetDefault "gmail";
          repositories.requests.preset = presetDefault [ "dotfiles" ];
        };
        home-manager.users.${username}.host.hm = presetDefault {
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
      })
      (lib.mkIf graphical {
        home-manager.users.${username}.host.hm = presetDefault {
          numberedWorkspaces = if config.nixpkgs.hostPlatform.isDarwin then 4 else 6;
          firefox = {
            enable = true;
            search.provider = "degoog";
          };
          gmailctl = {
            enable = true;
            warmer.enable = true;
          };
          hyprland.enable = !config.nixpkgs.hostPlatform.isDarwin;
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
