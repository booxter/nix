{ pkgs, ...}: let
  commonCfg = {
    realName = "Ihar Hrachyshka";
    flavor = "gmail.com";
    imap.host = "imap.gmail.com";
    smtp.host = "smtp.gmail.com";
    thunderbird.enable = true;
    mbsync = {
      enable = true;
      create = "maildir";
      extraConfig.account = {
        # throttle, https://people.kernel.org/mcgrof/replacing-offlineimap-with-mbsync
        PipelineDepth = 50;
        Create = "Near";
        Expunge = "Both";
      };
    };
    notmuch.enable = true;
  };
in {
  default = {
    primary = true;
    address = "ihar.hrachyshka@gmail.com";
    userName = "ihar.hrachyshka@gmail.com";
    passwordCommand = "${pkgs.pass}/bin/pass show priv/google.com-mutt";
  } // commonCfg;
  work = {
    address = "ihrachys@redhat.com";
    aliases = [ "ihar@redhat.com" ];
    userName = "ihrachys@redhat.com";
    passwordCommand = "${pkgs.pass}/bin/pass show rh/google.com-app-password-macpro";
  } // commonCfg;
}
