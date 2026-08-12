{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    certificateServices
    enabledServices
    secretName
    ;
  nginxSecret = key: {
    inherit key;
    owner = config.services.nginx.user;
    group = config.services.nginx.group;
    mode = "0400";
    restartUnits = [ "nginx.service" ];
  };
in
{
  config = lib.mkIf (enabledServices != { }) {
    host.internalPki.managedCertificates = lib.mkAfter (
      lib.mapAttrsToList (name: service: {
        category = "internal_https_server";
        inherit name;
        inherit (service) secretPrefix;
        certificateField = "server_crt_unencrypted";
      }) certificateServices
    );

    sops.secrets = lib.concatMapAttrs (serviceName: service: {
      "${secretName serviceName}-server-crt" =
        nginxSecret "${service.secretPrefix}/server_crt_unencrypted";
      "${secretName serviceName}-server-key" = nginxSecret "${service.secretPrefix}/server_key";
    }) enabledServices;
  };
}
