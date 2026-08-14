{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  username = config.host.username;
  presetDefault = lib.mkOverride 900;
in
{
  config = lib.mkIf (cfg.preset == "nvidia") (
    lib.mkMerge [
      {
        home-manager.users.${username}.host.hm = presetDefault {
          fullName = "Ihar Hrachyshka";
          email = "${username}@nvidia.com";
        };
      }
      (lib.mkIf cfg.roles.developer.enable {
        host.userEnvironment.sendEmail.transport = presetDefault "nvidia";
        home-manager.users.${username}.host.hm = presetDefault {
          dev = {
            act.enable = true;
            codex = {
              enable = true;
              usage.account = "corporate";
            };
            go.enable = true;
            k8s.enable = true;
            nvidia.enable = true;
          };
          docker.enable = true;
          sketchybar.attentionInbox.enable = true;
        };
      })
      (lib.mkIf cfg.roles.workstation.enable {
        host.userEnvironment.homerow.enable = presetDefault false;
        home-manager.users.${username}.host.hm = presetDefault {
          kitty.enable = true;
          matrix.enable = true;
          obsidian.enable = true;
          slack.enable = true;
          spotify = {
            enable = true;
            spicetify.enable = true;
          };
          teams.enable = true;
          telegram.enable = true;
          thunderbird = {
            enable = true;
            account = {
              flavor = "outlook.office365.com";
              imapAuthentication = "oauth2";
              smtp = {
                server = "mail.nvidia.com";
                authentication = "password";
              };
            };
          };
          wireshark.enable = true;
          zoom.enable = true;
        };
      })
    ]
  );
}
