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
  host.glance.instances = {
    internal = {
      enable = true;
      port = 18080;
      scope = "internal";
      search.provider = "degoog";
      sections = dashboardSections;
    };

    public = {
      enable = true;
      port = 18081;
      scope = "public";
      search.provider = "degoog";
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
      presentation = {
        title = "Dashboard";
        icon = "sh:glance";
      };
    };
  };
}
