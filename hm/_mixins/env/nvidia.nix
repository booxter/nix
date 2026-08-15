{ config, ... }:
{
  base = {
    host.hm = {
      fullName = "Ihar Hrachyshka";
      email = "${config.home.username}@nvidia.com";
    };
  };

  developer = {
    host.hm = {
      env.sendEmail.transport = "nvidia";
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
      pass.enable = true;
      podman = {
        enable = false;
        api.enable = false;
      };
    };
  };

  workstation = {
    host.hm = {
      env.homerow.enable = false;
      kitty.enable = true;
      matrix.enable = true;
      obsidian.enable = true;
      sketchybar.attentionInbox.enable = true;
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
  };
}
