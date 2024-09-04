{ pkgs, ... }: {
  enable = true;
  # I patch thunderbird profiles in my fork to exclude Version=
  darwinSetupWarning = false;
  # fake package; we use homebrew
  package = pkgs.runCommand "thunderbird.0.0" {} "mkdir $out";
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
  };
}
