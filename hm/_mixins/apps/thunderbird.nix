{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  cfg = config.host.hm.thunderbird;
  identity = config.host.hm.user.${cfg.user};
  authenticationMethod = {
    oauth2 = 10;
    password = 3;
  };
  authenticationType = lib.types.enum (builtins.attrNames authenticationMethod);
  thunderbirdProfilesPath = if isDarwin then "Library/Thunderbird/Profiles" else ".thunderbird";
in
{
  options.host.hm.thunderbird = {
    enable = lib.mkEnableOption "managed Thunderbird email client";

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Named host.hm.user identity configured in Thunderbird.";
    };

    account = {
      flavor = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Home Manager email-provider flavor.";
      };

      imapAuthentication = lib.mkOption {
        type = authenticationType;
        default = "oauth2";
        description = "Authentication method used for incoming email.";
      };

      smtp = {
        server = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "SMTP server hostname.";
        };

        authentication = lib.mkOption {
          type = authenticationType;
          default = "oauth2";
          description = "Authentication method used for outgoing email.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.host.hm.user;
        message = "host.hm.thunderbird.user must name a declared host.hm.user identity";
      }
    ];

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
          "mail.threadpane.listview" = 1;

          "mail.ui.folderpane.view" = 1;
          "mail.folder.views.version" = 1;

          # Check IMAP subfolder for new messages
          "mail.check_all_imap_folders_for_new" = true;
          "mail.server.default.check_all_folders_for_new" = true;

          # Use the system browser for OAuth flows.
          "mailnews.oauth.useExternalBrowser" = true;

          # Default the compose window and send path to plain text.
          "mail.default_send_format" = 1;
        };
      };
    };

    accounts.email.accounts.default = {
      inherit (cfg.account) flavor;
      address = identity.email;
      realName = identity.fullName;
      primary = true;
      smtp.host = lib.mkForce cfg.account.smtp.server;
      thunderbird = {
        enable = true;
        perIdentitySettings = id: {
          # The account UI stores "Compose messages in HTML format" per identity.
          "mail.identity.id_${id}.compose_html" = false;
        };
        settings = id: {
          "mail.server.server_${id}.authMethod" = authenticationMethod.${cfg.account.imapAuthentication};
          # Thunderbird treats this as a filesystem path during folder/filter
          # validation; keep it absolute.
          "mail.server.server_${id}.directory" =
            "${config.home.homeDirectory}/${thunderbirdProfilesPath}/default/ImapMail/${id}";
          "mail.smtpserver.smtp_${id}.authMethod" = authenticationMethod.${cfg.account.smtp.authentication};
        };
      };
    };
  };
}
