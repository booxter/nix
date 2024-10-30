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
      settings = {
        drop_non_existing_label = true;
        # TODO: it would be nice to extend lieer so that it sync a limited list
        # of tags instead of enumerating all tags that should NOT be synced
        # Probably relevant: https://github.com/gauteh/lieer/issues/263
        ignore_tags = [
          "Archives"
          "Boss"
          "Bugs"
          "Bugs/Support"
          "Calendar"
          "Care.com"
          "Discuss"
          "Discuss/Cloud"
          "Discuss/ocp"
          "Discuss/osp"
          "Discuss/ovs"
          "Discuss/rh"
          "Discuss/rhelai"
          "Github"
          "Merged"
          "Merged/ovs"
          "Review"
          "Review/ilab"
          "Review/next-gen"
          "Review/ocp"
          "Review/ovs"
          "Waiting"
          "Workday"
        ];
      };
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
