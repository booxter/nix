{ pkgs, username, ... }: {
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
        smtpUser = "${username}@redhat.com";
    };
    rerere.enabled = true;
    branch.sort = "-committerdate";

    merge.mergigraf = {
      name = "mergiraf";
      driver = "mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P";
    };

    core.attributesfile = "${pkgs.writeText "gitattributes" ''
      *.java merge=mergiraf
      *.rs merge=mergiraf
      *.go merge=mergiraf
      *.js merge=mergiraf
      *.jsx merge=mergiraf
      *.json merge=mergiraf
      *.yml merge=mergiraf
      *.yaml merge=mergiraf
      *.html merge=mergiraf
      *.htm merge=mergiraf
      *.xhtml merge=mergiraf
      *.xml merge=mergiraf
      *.c merge=mergiraf
      *.cc merge=mergiraf
      *.h merge=mergiraf
      *.cpp merge=mergiraf
      *.hpp merge=mergiraf
      *.cs merge=mergiraf
      *.dart merge=mergiraf
    ''}";
  };

  diff-so-fancy.enable = true;
  diff-so-fancy.markEmptyLines = true;

  }
