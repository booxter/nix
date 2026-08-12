{
  cloudQosEnabled,
  config,
  hostName,
  lib,
  localClients,
  model,
}:
let
  formatRequest = request: "${request.clientName}.${request.destinationName} -> ${request.server}";
in
lib.optional cloudQosEnabled {
  assertion = config.host.network.primaryInterface != null;
  message = "backup cloud-offload policy requires host.network.primaryInterface";
}
++ [
  {
    assertion = model.unknownServers == [ ];
    message = "backup destinations reference unknown or disabled servers: ${
      lib.concatMapStringsSep ", " formatRequest model.unknownServers
    }";
  }
  {
    assertion = model.missingPublicKeys == [ ];
    message = "remote backup destinations require client public keys: ${
      lib.concatMapStringsSep ", " formatRequest model.missingPublicKeys
    }";
  }
  {
    assertion = model.duplicateClientServers == [ ];
    message = "backup clients may define only one destination per server: ${lib.concatStringsSep ", " model.duplicateClientServers}";
  }
  {
    assertion = model.duplicateRepositoryPaths == [ ];
    message = "backup destinations resolve to duplicate repository paths: ${lib.concatStringsSep ", " model.duplicateRepositoryPaths}";
  }
  {
    assertion = model.invalidB2RepositoryRoots == [ ];
    message = "B2 offsite repository roots must contain their bucket name: ${lib.concatStringsSep ", " model.invalidB2RepositoryRoots}";
  }
  {
    assertion = builtins.length localClients <= 1;
    message = "backup server ${hostName} may have at most one local client";
  }
]
