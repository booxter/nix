{ lanDomain }:
{
  home = {
    secretDomain = "main";
    services = {
      attic = {
        cacheName = "local";
        endpoint = "https://nix-cache.${lanDomain}";
      };
      observability = {
        loki = {
          writeUrl = "https://loki.${lanDomain}/loki/api/v1/push";
          mtls = true;
        };
        nodeExporter.mtls = true;
      };
    };
  };

  work = {
    secretDomain = "work";
    services = { };
  };
}
