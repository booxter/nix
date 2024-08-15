{ pkgs, ... }: {
  enable = true;
  package = pkgs.gitAndTools.gitFull;
  userEmail = "ihar.hrachyshka@gmail.com";
  userName = "Ihar Hrachyshka";
  ignores = [
    "*.swp"
  ];

  extraConfig = {
    pw = {
      server = "https://patchwork.ozlabs.org/api/1.2";
      project = "ovn";
    };
    sendemail = {
      confirm = "auto";
      smtpServer = "smtp.gmail.com";
      smtpServerPort = 587;
      smtpEncryption = "tls";
        # TODO: pass name as argument
        smtpUser = "ihrachys@redhat.com";
      };
      rerere.enabled = true;
      branch.sort = "-committerdate";
    };

    diff-so-fancy.enable = true;
    diff-so-fancy.markEmptyLines = false;
  }
