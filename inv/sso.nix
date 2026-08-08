let
  mkUsers = builtins.mapAttrs (
    name: groups: {
      inherit groups;
      displayName = name;
      mailAddressSopsKey = "kanidm/person_mail_addresses/${name}";
    }
  );
in
{
  administrator = "ihar";

  applications = {
    audiobookshelf = {
      adminGroup = "media-admins";
      userGroup = "media-users";
    };
    degoog.userGroup = "degoog-users";
    "home-assistant" = {
      adminGroup = "home-admins";
      userGroup = "home-users";
    };
    pinepods = {
      adminGroup = "media-admins";
      userGroup = "media-users";
    };
    paperless = {
      adminGroup = "paperless-admins";
      userGroup = "paperless-users";
    };
    romm = {
      adminGroup = "romm-admins";
      editorGroup = "romm-editors";
      viewerGroup = "romm-viewers";
    };
    vikunja.userGroup = "vikunja-users";
    watchstate = {
      adminGroup = "media-admins";
    };
  };

  groups = {
    "infra-admins" = {
      title = "Infrastructure administrators";
    };
    "grafana-admins" = {
      title = "Grafana administrators";
    };
    "grafana-viewers" = {
      title = "Grafana viewers";
    };
    "home-admins" = {
      title = "Home Assistant administrators";
    };
    "home-users" = {
      title = "Home Assistant users";
    };
    "paperless-admins" = {
      title = "Paperless administrators";
    };
    "paperless-users" = {
      title = "Paperless users";
    };
    "vikunja-users" = {
      title = "Vikunja users";
    };
    "degoog-users" = {
      title = "Degoog users";
    };
    "romm-admins" = {
      title = "RomM administrators";
    };
    "romm-editors" = {
      title = "RomM editors";
    };
    "romm-viewers" = {
      title = "RomM viewers";
    };
    "media-admins" = {
      title = "Media administrators";
    };
    "media-users" = {
      title = "Media users";
    };
  };

  users = mkUsers {
    ihar = [
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
    kasia = [
      "paperless-users"
      "vikunja-users"
      "degoog-users"
      "media-admins"
      "media-users"
      "romm-viewers"
      "home-users"
    ];
    eugene = [
      "degoog-users"
      "media-users"
      "vikunja-users"
      "romm-viewers"
    ];
  };
}
