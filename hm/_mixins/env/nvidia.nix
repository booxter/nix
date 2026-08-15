{
  config,
  lib,
  osConfig,
  ...
}:
let
  cfg = config.host.hm.env;
  presetDefault = lib.mkOverride 900;
in
{
  config = lib.mkIf (cfg.preset == "nvidia") (
    lib.mkMerge [
      {
        host.hm = presetDefault {
          fullName = "Ihar Hrachyshka";
          email = "${config.home.username}@nvidia.com";
        };
      }
      (lib.mkMerge [
        {
          host.hm.env.sendEmail.transport = presetDefault "nvidia";
        }
        {
          host.hm = presetDefault {
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
            podman = {
              enable = false;
              api.enable = false;
            };
            sketchybar.attentionInbox.enable = true;
          };
        }
      ])
      (lib.mkIf (osConfig.host.desktop != null) (
        lib.mkMerge [
          {
            host.hm.env.homerow.enable = presetDefault false;
          }
          {
            host.hm = presetDefault {
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
          }
        ]
      ))
    ]
  );
}
