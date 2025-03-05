{ lib, pkgs, ... }:
{
  # Thunderbird
  programs.thunderbird = {
    enable = true;
    darwinSetupWarning = false;
    package = if pkgs.stdenv.isDarwin then pkgs.thunderbird-unwrapped else pkgs.thunderbird;
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
        "javascript.enabled" = false;
        "mail.uidensity" = 0;

        "mail.ui.folderpane.view" = 1;
        "mail.folder.views.version" = 1;

        # Check IMAP subfolder for new messages
        "mail.check_all_imap_folders_for_new" = true;
        "mail.server.default.check_all_folders_for_new" = true;
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

  # generated profiles imply this setting
  home.sessionVariables = {
    MOZ_LEGACY_PROFILES = 1;
    MOZ_ALLOW_DOWNGRADE = 1;
  };

  # Accounts
  accounts.email.accounts =
    let
      commonCfg = {
        realName = "Ihar Hrachyshka";
        flavor = "gmail.com";
        imap.host = "imap.gmail.com";
        smtp.host = "smtp.gmail.com";
        thunderbird.enable = true;
        msmtp.enable = true;
      };
    in
    {
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
    };

  # Misc email tools
  programs.msmtp.enable = true;

  home.packages = with pkgs; [
    gmailctl
    mailsend-go
  ];
}
