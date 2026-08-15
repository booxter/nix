{ pkgs, ... }:
{
  base = {
    host.hm = {
      fullName = "Ihar Hrachyshka";
      email = "ihar.hrachyshka@gmail.com";
    };
  };

  developer = {
    host.hm = {
      env = {
        sendEmail.transport = "gmail";
        repositories.requests.developer = [ "dotfiles" ];
      };
      dev = {
        act.enable = true;
        codex = {
          enable = true;
          usage.warmer.enable = true;
        };
        go.enable = true;
      };
      pass.enable = true;
      podman.enable = true;
      ramalama.enable = true;
    };
  };

  workstation = {
    host.hm = {
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
  };
}
