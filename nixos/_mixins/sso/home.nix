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

    groups = {
      sso-admins.title = "SSO administrators";
      infra-admins.title = "Infrastructure administrators";
      grafana-admins.title = "Grafana administrators";
      grafana-viewers.title = "Grafana viewers";
      home-admins.title = "Home Assistant administrators";
      home-users.title = "Home Assistant users";
      paperless-admins.title = "Paperless administrators";
      paperless-users.title = "Paperless users";
      vikunja-users.title = "Vikunja users";
      degoog-users.title = "Degoog users";
      romm-admins.title = "RomM administrators";
      romm-editors.title = "RomM editors";
      romm-viewers.title = "RomM viewers";
      media-admins.title = "Media administrators";
      media-users.title = "Media users";
    };

    users = {
      ihar = {
        displayName = "ihar";
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
        displayName = "kasia";
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
        displayName = "eugene";
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
