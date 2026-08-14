{ config, ... }:
let
  internalPort = 18080;
  publicPort = 18081;
  dashboardSections = [
    {
      id = "user";
      title = "User Apps";
    }
    {
      id = "media-admin";
      title = "Media Admin";
    }
    {
      id = "infrastructure";
      title = "Infrastructure";
    }
  ];
in
{
  host.glance.search.provider = "degoog";

  host.glance.instances = {
    internal = {
      port = internalPort;
      sections = dashboardSections;
    };

    public = {
      port = publicPort;
      sections = builtins.filter (section: section.id == "user") dashboardSections;
    };
  };

  host.web.services = {
    glance = {
      upstream = "http://127.0.0.1:${toString internalPort}";
      internal.publicAliases = [ config.host.web.services.dash.public.hostName ];
    };

    dash = {
      upstream = "http://127.0.0.1:${toString publicPort}";
      public = {
        enable = true;
        hostName = "dash.${config.host.network.publicDomain}";
        serveOnOwner = false;
        splitDnsHost = config.networking.hostName;
      };
      health.frontend.enable = true;
      observability = {
        importance = "critical";
        externalProbe.requirement = "required";
      };
      displayName = "Dashboard";
      dashboard = {
        enable = false;
        icon = "sh:glance";
        section = null;
      };
    };
  };
}
