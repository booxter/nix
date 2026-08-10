{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  userEnvironment = osConfig.host.userEnvironment;
  emailCfg = userEnvironment.features.email;
  emailAccount = userEnvironment.emailAccounts.${emailCfg.account};
  identity = userEnvironment.identities.${emailAccount.identity};
  smtpTransport = userEnvironment.smtpTransports.${emailAccount.smtpTransport};
  authenticationMethod = {
    oauth2 = 10;
    password = 3;
  };
  thunderbirdProfilesPath = if isDarwin then "Library/Thunderbird/Profiles" else ".thunderbird";
in
{
  imports = [ ./gmailctl.nix ];

  # Thunderbird
  programs.thunderbird = lib.mkIf (emailCfg.enable && emailCfg.thunderbird.enable) {
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

  # Accounts
  accounts.email.accounts = lib.mkIf emailCfg.enable (
    let
      commonCfg = {
        realName = identity.fullName;
        thunderbird = {
          enable = emailCfg.thunderbird.enable;
          perIdentitySettings = id: {
            # The account UI stores "Compose messages in HTML format" per identity.
            "mail.identity.id_${id}.compose_html" = false;
          };
          settings = id: {
            "mail.server.server_${id}.authMethod" = authenticationMethod.${emailAccount.imapAuthentication};
            # Thunderbird treats this as a filesystem path during folder/filter
            # validation; keep it absolute.
            "mail.server.server_${id}.directory" =
              "${config.home.homeDirectory}/${thunderbirdProfilesPath}/default/ImapMail/${id}";
            "mail.smtpserver.smtp_${id}.authMethod" = authenticationMethod.${emailAccount.smtpAuthentication};
          };
        };
        primary = true;
      };
    in
    {
      default = {
        inherit (emailAccount) flavor;
        address = identity.email;
        smtp.host = lib.mkForce smtpTransport.server;
      }
      // commonCfg;
    }
  );

}
