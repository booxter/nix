{ config, lib, ... }:
lib.mkIf (config.host.realm == "home") {
  host.sso = {
    providerHost = "pki";

    applications = {
      audiobookshelf = {
        roles = {
          admin = "media-admins";
          user = "media-users";
        };
      };
      aurral = {
        roles = {
          admin = "media-admins";
          user = "media-users";
        };
      };
      "home-assistant" = {
        roles = {
          admin = "home-admins";
          user = "home-users";
        };
        bootstrapOwner = "ihar";
      };
      paperless = {
        roles = {
          admin = "paperless-admins";
          user = "paperless-users";
        };
        bootstrapOwner = "ihar";
      };
      pinepods = {
        roles = {
          admin = "media-admins";
          user = "media-users";
        };
        bootstrapOwner = "ihar";
      };
      romm = {
        roles = {
          admin = "romm-admins";
          editor = "romm-editors";
          viewer = "romm-viewers";
        };
        bootstrapOwner = "ihar";
      };
      shelfmark = {
        roles = {
          admin = "media-admins";
          user = "media-users";
        };
      };
      watchstate = {
        roles.admin = "media-admins";
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
          "media-admins"
          "media-users"
          "romm-viewers"
          "home-users"
        ];
      };
      eugene = {
        mailAddressSopsKey = "kanidm/person_mail_addresses/eugene";
        groups = [
          "media-users"
          "vikunja-users"
          "romm-viewers"
        ];
      };
    };
  };
}
