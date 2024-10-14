{ pkgs, ...}: let
  offlineimap-config = {
    offlineimap = {
      enable = true;
      extraConfig.remote = {
        folderfilter = "lambda name: name not in ['[Gmail]/All Mail']";
      };
    };
  };
in {
  default = {
    primary = true;
    realName = "Ihar Hrachyshka";
    flavor = "gmail.com";
    address = "ihar.hrachyshka@gmail.com";
    userName = "ihar.hrachyshka@gmail.com";
    passwordCommand = "${pkgs.pass}/bin/pass show priv/google.com-mutt";
    imap.host = "imap.gmail.com";
    smtp.host = "smtp.gmail.com";
    thunderbird.enable = true;
    offlineimap = offlineimap-config;
    notmuch.enable = true;
  } // offlineimap-config;
  work = {
    realName = "Ihar Hrachyshka";
    flavor = "gmail.com";
    address = "ihrachys@redhat.com";
    aliases = [ "ihar@redhat.com" ];
    userName = "ihrachys@redhat.com";
    passwordCommand = "${pkgs.pass}/bin/pass show rh/google.com-app-password-macpro";
    imap.host = "imap.gmail.com";
    smtp.host = "smtp.gmail.com";
    thunderbird.enable = true;
    notmuch.enable = true;
  } // offlineimap-config;
}
