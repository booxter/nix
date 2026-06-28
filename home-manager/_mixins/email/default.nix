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
  gmailctlConfigDir = "${config.home.homeDirectory}/.gmailctl";
  gmailctlExe = lib.getExe' pkgs.gmailctl "gmailctl";
  gmailctlKeepalive = pkgs.writeShellApplication {
    name = "gmailctl-token-keepalive";
    text = ''
      exec ${gmailctlExe} --color=never --config ${lib.escapeShellArg gmailctlConfigDir} download --output /dev/null
    '';
  };
in
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

  home.packages = with pkgs; [
    gmailctl
  ];

  launchd.agents.gmailctl-token-keepalive = lib.mkIf (!isWork && isDarwin) {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe gmailctlKeepalive) ];
      ProcessType = "Background";
      StartCalendarInterval = {
        Weekday = 1;
        Hour = 10;
        Minute = 0;
      };
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/gmailctl-token-keepalive.log";
    };
  };

  systemd.user.services.gmailctl-token-keepalive = lib.mkIf (!isWork && !isDarwin) {
    Unit.Description = "Keep gmailctl OAuth refresh token active";

    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe gmailctlKeepalive;
    };
  };

  systemd.user.timers.gmailctl-token-keepalive = lib.mkIf (!isWork && !isDarwin) {
    Unit.Description = "Keep gmailctl OAuth refresh token active";

    Timer = {
      OnCalendar = "weekly";
      Persistent = true;
    };

    Install.WantedBy = [ "timers.target" ];
  };
}
