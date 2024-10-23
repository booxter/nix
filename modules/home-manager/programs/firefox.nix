{ pkgs, lib, ... }: {
  enable = true;
  package = pkgs.firefox-unwrapped;
  nativeMessagingHosts = [
    pkgs.browserpass
  ];
  profiles.default = {
    search.default = "DuckDuckGo";
    search.privateDefault = "DuckDuckGo";
    search.force = true;
    settings = {
      # enable installed extensions
      "extensions.autoDisableScopes" = 0;

      # I know what I'm doing
      "browser.aboutConfig.showWarning" = false;
      "browser.translations.neverTranslateLanguages" = "en,ru,be,uk,cz,pl";

      # UX fixes
      "browser.startup.homepage" = "about:blank";
      "browser.newtab.url" = "about:blank";
      "browser.ctrlTab.sortByRecentlyUsed" = false;
      "browser.tabs.closeWindowWithLastTab" = true;
      "accessibility.typeaheadfind.enablesound" = false;
      "browser.tabs.tabmanager.enabled" = true;

      # don't pollute home for no reason
      "browser.download.start_downloads_in_tmp_dir" = true;
      "browser.download.folderList" = 2; # use the last dir
      "browser.download.useDownloadDir" = true;
      "browser.download.dir" = "/tmp";

      "media.block-autoplay-until-in-foreground" = true;
      "media.block-play-until-document-interaction" = true;
      "media.block-play-until-visible" = true;

      # privacy
      "geo.enabled" = true;
      "privacy.clearOnShutdown.history" = false;
      "privacy.donottrackheader.enabled" = true;
      "privacy.trackingprotection.enabled" = true;
      "privacy.trackingprotection.socialtracking.enabled" = true;
      "device.sensors.enabled" = false;
      "beacon.enabled" = false; # bluetooth location tracking

      # telemetry
      "browser.send_pings" = false;
      "toolkit.telemetry.archive.enabled" = false;
      "toolkit.telemetry.enabled" = false;
      "toolkit.telemetry.server" = "";
      "toolkit.telemetry.unified" = false;
      "extensions.webcompat-reporter.enabled" = false;
      "datareporting.policy.dataSubmissionEnabled" = false;
      "datareporting.healthreport.uploadEnabled" = false;
      "browser.ping-centre.telemetry" = false;
      "browser.urlbar.eventTelemetry.enabled" = false; # (default)
      "browser.tabs.crashReporting.sendReport" = false;

      # don't allow mozilla to test config changes
      "app.normandy.enabled" = false;
      "app.shield.optoutstudies.enabled" = false;

      # Disable some useless stuff
      "extensions.pocket.enabled" = false; # disable pocket, save links, send tabs
      "browser.vpn_promo.enabled" = false;
      "extensions.abuseReport.enabled" = false; # don't show 'report abuse' in extensions
      "identity.fxaccounts.enabled" = false; # disable firefox login
      "identity.fxaccounts.toolbar.enabled" = false;
      "identity.fxaccounts.pairing.enabled" = false;
      "identity.fxaccounts.commands.enabled" = false;
      "browser.contentblocking.report.lockwise.enabled" = false; # don't use firefox password manager
      "browser.uitour.enabled" = false; # no tutorial please
      "browser.newtabpage.activity-stream.showSponsored" = false;
      "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;

      # disable annoying web features
      "dom.push.enabled" = false; # push notifications
      "dom.push.connection.enabled" = false;
      "dom.battery.enabled" = false; # you don't need to see my battery...
      "dom.private-attribution.submission.enabled" = false; # No PPA

      # krb gss login
      "network.negotiate-auth.trusted-uris" = "redhat.com";
    };
    extensions = with pkgs.nur.repos.rycee.firefox-addons; [
      browserpass
      privacy-badger
      ublock-origin
      vimium
      # https://addons.mozilla.org/api/v5/addons/search/?q=readwise-highlighter
      (with lib; buildFirefoxXpiAddon {
        pname = "readwise-highlighter";
        version = "0.15.23";
        addonId = "team@readwise.io";
        url = "https://addons.mozilla.org/firefox/downloads/file/4222692/readwise_highlighter-0.15.23.xpi";
        #sha256 = lib.fakeSha256;
        sha256 = "sha256-Jg62eKy7s3tbs0IR/zHOSzLpQVj++wTUYyPU4MUBipQ=";
        meta = {
          homepage = "https://read.readwise.io/";
          description = "Readwise Highlighter";
          license = {
            fullName = "All Rights Reserved";
            free = false;
          };
          mozPermissions = [
            "<all_urls>"
            "activeTab"
            "background"
            "contextMenus"
            "notifications"
            "storage"
            "tabs"
            "unlimitedStorage"
          ];
          platforms = platforms.all;
        };
      })
    ];
  };
}
