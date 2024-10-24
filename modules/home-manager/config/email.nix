{ pkgs, ...}: let
  commonCfg = {
    realName = "Ihar Hrachyshka";
    flavor = "gmail.com";
    imap.host = "imap.gmail.com";
    smtp.host = "smtp.gmail.com";
    thunderbird.enable = true;
    notmuch.enable = true;
    lieer = {
      enable = true;
      settings.drop_non_existing_label = true;
    };
    msmtp.enable = true;
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
