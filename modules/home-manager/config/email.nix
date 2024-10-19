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
      expunge = "both";
      patterns = ["*" "![Gmail]*" "[Gmail]/Sent Mail" "[Gmail]/Starred" "[Gmail]/All Mail"];
      extraConfig = {
        channel.Sync = "All";
        # throttle, https://people.kernel.org/mcgrof/replacing-offlineimap-with-mbsync
        account.PipelineDepth = 50;
      };
    };
    notmuch.enable = true;
    lieer.enable = true;
    msmtp.enable = true;

    folders = {
      drafts = "drafts";
      inbox = "inbox";
      sent = "sent";
      trash = "trash";
    };
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
