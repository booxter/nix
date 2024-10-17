{ pkgs, ...}: {
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
    mbsync.enable = true;
    notmuch.enable = true;
  };
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
    mbsync.enable = true;
    notmuch.enable = true;
  };
}
