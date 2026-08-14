{ config, ... }:
let
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
      port = 18080;
      sections = dashboardSections;
    };

    public = {
      port = 18081;
      sections = builtins.filter (section: section.id == "user") dashboardSections;
    };
  };

  host.web.services = {
    glance = {
      enable = true;
      upstream = config.host.glance.instances.internal.upstream;
      internal.publicAliases = [ config.host.web.services.dash.public.hostName ];
    };

    dash = {
      enable = true;
      upstream = config.host.glance.instances.public.upstream;
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
