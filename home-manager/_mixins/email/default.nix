{ pkgs, username, isWork, ... }:
{
  # Thunderbird
  programs.thunderbird = {
    enable = true;
    package = pkgs.thunderbird;
    profiles.default = {
      isDefault = true;
      settings = {
        # Sort by date in descending order using threaded view
        "mailnews.default_sort_type" = 18;
        "mailnews.default_sort_order" = 2;
        "mailnews.default_view_flags" = 1;
        "mailnews.default_news_sort_type" = 18;
        "mailnews.default_news_sort_order" = 2;
        "mailnews.default_news_view_flags" = 1;

        # Disable autoupdates
        "app.update.auto" = false;
        "app.update.staging.enabled" = false;

        # Remove some ui bloat
        "mailnews.start_page.enabled" = false;
        "mail.uidensity" = 0;

        "mail.ui.folderpane.view" = 1;
        "mail.folder.views.version" = 1;

        # Check IMAP subfolder for new messages
        "mail.check_all_imap_folders_for_new" = true;
        "mail.server.default.check_all_folders_for_new" = true;

        # auth not working for google without it for some reason
        "javascript.enabled" = true;
        "general.useragent.compatMode.firefox" = true;
      };
    };
  };

  # Accounts
  accounts.email.accounts = 
    let
      commonCfg = {
        realName = "Ihar Hrachyshka";
        thunderbird = {
          enable = true;
          settings = id: {
            "mail.server.server_${id}.authMethod" = 10; # OAuth2
            "mail.smtpserver.smtp_${id}.authMethod" = 10; # OAuth2
          };
        };
        msmtp.enable = true;
        primary = true;
      };
    in
    {
      default = (if isWork then {
        flavor = "outlook.office365.com";
        address = "${username}@nvidia.com";
      } else {
        flavor = "gmail.com";
        address = "ihar.hrachyshka@gmail.com";
        passwordCommand = "${pkgs.pass}/bin/pass show priv/google.com-mutt";
      }) // commonCfg;
    };

  # Misc email tools
  programs.msmtp.enable = true;

  home.packages = with pkgs; [
    gmailctl
  ];
}
