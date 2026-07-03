{
  config,
  lib,
  pkgs,
  username,
  isDarwin,
  isWork,
  ...
}:
let
  thunderbirdProfilesPath = if isDarwin then "Library/Thunderbird/Profiles" else ".thunderbird";
in
{
  imports = lib.optionals (!isWork) [
    ./gmailctl.nix
  ];

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
  accounts.email.accounts =
    let
      commonCfg = {
        realName = "Ihar Hrachyshka";
        thunderbird = {
          enable = true;
          perIdentitySettings = id: {
            # The account UI stores "Compose messages in HTML format" per identity.
            "mail.identity.id_${id}.compose_html" = false;
          };
          settings = id: {
            "mail.server.server_${id}.authMethod" = 10; # OAuth2
            # Thunderbird treats this as a filesystem path during folder/filter
            # validation; keep it absolute.
            "mail.server.server_${id}.directory" =
              "${config.home.homeDirectory}/${thunderbirdProfilesPath}/default/ImapMail/${id}";
            "mail.smtpserver.smtp_${id}.authMethod" =
              if isWork then
                3 # plain
              else
                10; # OAuth2
          };
        };
        msmtp.enable = true;
        primary = true;
      };
    in
    {
      default =
        (
          if isWork then
            {
              flavor = "outlook.office365.com";
              address = "${username}@nvidia.com";
              smtp.host = lib.mkForce "mail.nvidia.com";
            }
          else
            {
              flavor = "gmail.com";
              address = "ihar.hrachyshka@gmail.com";
              passwordCommand = "${pkgs.pass}/bin/pass show priv/google.com-mutt";
            }
        )
        // commonCfg;
    };

  # Misc email tools
  programs.msmtp.enable = true;
}
