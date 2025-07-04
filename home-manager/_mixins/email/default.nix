{ lib, pkgs, isPrivate, ... }:
{
  # Thunderbird
  programs.thunderbird = {
    enable = true;
    package = pkgs.thunderbird;
    nativeMessagingHosts = with pkgs; [
      cb_thunderlink-native
    ];
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
      extensions = with pkgs.nur.repos.rycee.firefox-addons; [
        # https://addons.thunderbird.net/api/v4/addons/search/?q=cb_thunderlink
        (
          with lib;
          buildFirefoxXpiAddon {
            pname = "cb_thunderlink";
            version = "1.7.4";
            addonId = "cb_thunderlink@bouchier.be";
            url = "https://github.com/CamielBouchier/cb_thunderlink/releases/download/Release_1_7_4/cb_thunderlink.xpi";
            sha256 = "sha256-r0xS/k3davx9BsBhtxh17txdlmws3h9hNRxhk/CW/HI=";
            meta = {
              description = "Durable hyperlinks to specific email messages";
              license = licenses.mit;
              mozPermissions = [
                "accountsRead"
                "clipboardRead"
                "clipboardWrite"
                "menus"
                "messagesRead"
                "nativeMessaging"
                "storage"
              ];
              platforms = platforms.all;
            };
          }
        )
      ];
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
      default = (if isPrivate then {
        flavor = "gmail.com";
        address = "ihar.hrachyshka@gmail.com";
        passwordCommand = "${pkgs.pass}/bin/pass show priv/google.com-mutt";
      } else {
        flavor = "outlook.office365.com";
        address = "ihrachyshka@nvidia.com";
      }) // commonCfg;
    };

  # Misc email tools
  programs.msmtp.enable = true;

  home.packages = lib.optionals isPrivate (with pkgs; [
    gmailctl
  ]);
}
