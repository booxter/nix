{
  bucketNames,
  clients,
  cloudQosEnabled,
  config,
  hostName,
  lib,
  localClients,
  providedLinks,
  provider,
}:
lib.optional cloudQosEnabled {
  assertion = config.host.network.primaryInterface != null;
  message = "backup cloud-offload policy requires host.network.primaryInterface";
}
++ lib.optionals (provider != null) [
  {
    assertion = builtins.length localClients <= 1;
    message = "backup provider ${hostName} may have at most one local client";
  }
  {
    assertion = builtins.length bucketNames == 1;
    message = "backup provider ${hostName} currently requires one shared cloud bucket";
  }
  {
    assertion =
      builtins.length (builtins.attrNames clients) == builtins.length (builtins.attrNames providedLinks);
    message = "backup provider ${hostName} may have only one link per client";
  }
]
