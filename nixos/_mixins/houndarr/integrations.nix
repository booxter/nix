{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  instances = builtins.filter (instance: instance.apiRegistration != null) (
    builtins.attrValues model.instances
  );
  apiConfig = instance: instance.apiRegistration;
  allowConfig = api: lib.concatMapStringsSep "\n" (cidr: "allow ${cidr};") api.allowedCidrs;
  apiLocation = api: {
    proxyPass = api.service.upstream;
    recommendedProxySettings = true;
    extraConfig = ''
      auth_request off;
      ${allowConfig api}
      deny all;
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    services.nginx.virtualHosts = lib.mkMerge (
      map (
        instance:
        let
          api = apiConfig instance;
          vhost = "internal-https-${api.service.internal.endpointName}-probe";
        in
        {
          ${vhost}.locations = {
            ${api.path} = apiLocation api;
          };
        }
      ) instances
    );
  };
}
