{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.sso = {
    providerHost = "pki";

    applications = {
      audiobookshelf = {
        adminGroup = "media-admins";
        userGroup = "media-users";
      };
      aurral = {
        adminGroup = "media-admins";
        userGroup = "media-users";
      };
      "home-assistant" = {
        adminGroup = "home-admins";
        userGroup = "home-users";
        bootstrapOwner = "ihar";
        bootstrapLanguage = "en";
      };
      degoog = {
        adminGroup = "infra-admins";
        userGroup = "degoog-users";
      };
      paperless = {
        adminGroup = "paperless-admins";
        userGroup = "paperless-users";
        bootstrapOwner = "ihar";
      };
      pinepods = {
        adminGroup = "media-admins";
        userGroup = "media-users";
        bootstrapOwner = "ihar";
      };
      romm = {
        adminGroup = "romm-admins";
        editorGroup = "romm-editors";
        viewerGroup = "romm-viewers";
        bootstrapOwner = "ihar";
      };
      shelfmark = {
        adminGroup = "media-admins";
        userGroup = "media-users";
      };
      watchstate = {
        adminGroup = "media-admins";
        bootstrapOwner = "ihar";
      };
    };

    groups = [
      "sso-admins"
      "infra-admins"
      "grafana-admins"
      "grafana-viewers"
      "home-admins"
      "home-users"
      "paperless-admins"
      "paperless-users"
      "vikunja-users"
      "degoog-users"
      "romm-admins"
      "romm-editors"
      "romm-viewers"
      "media-admins"
      "media-users"
    ];

    users = {
      ihar = {
        mailAddressSopsKey = "kanidm/person_mail_addresses/ihar";
        groups = [
          "sso-admins"
          "infra-admins"
          "grafana-admins"
          "home-admins"
          "home-users"
          "paperless-admins"
          "paperless-users"
          "vikunja-users"
          "degoog-users"
          "romm-admins"
          "media-admins"
          "media-users"
        ];
      };
      kasia = {
        mailAddressSopsKey = "kanidm/person_mail_addresses/kasia";
        groups = [
          "paperless-users"
          "vikunja-users"
          "degoog-users"
          "media-admins"
          "media-users"
          "romm-viewers"
          "home-users"
        ];
      };
      eugene = {
        mailAddressSopsKey = "kanidm/person_mail_addresses/eugene";
        groups = [
          "degoog-users"
          "media-users"
          "vikunja-users"
          "romm-viewers"
        ];
      };
    };
  };
}
