{
  lib,
  webModel,
  ...
}:
let
  policyName = "media-admin";
  gateName = "srvarr-admin-apps";
  cookieName = "_srvarr_admin_sso";
  services = lib.filterAttrs (
    _: service: service.auth.policy == policyName
  ) webModel.normalizedInternalServices;
  serviceNames = builtins.attrNames services;
  endpointNames = map (name: services.${name}.internal.endpointName) serviceNames;
  clearCookieConfig =
    lib.concatMapStringsSep "\n"
      (
        suffix:
        ''add_header Set-Cookie "${cookieName}${suffix}=; Path=/; Max-Age=0; HttpOnly; Secure" always;''
      )
      [
        ""
        "_0"
        "_1"
        "_2"
        "_csrf"
      ];
  logoutLocations = lib.mapAttrs' (
    _name: service:
    lib.nameValuePair service.internal.endpointName (
      builtins.listToAttrs (
        map (path: {
          name = "= ${path}";
          value = {
            return = "204";
            extraConfig = ''
              auth_request off;
              ${clearCookieConfig}
            '';
          };
        }) service.auth.sessionClearPaths
      )
    )
  ) (lib.filterAttrs (_: service: service.auth.sessionClearPaths != [ ]) services);
in
{
  config = lib.mkIf (services != { }) {
    # TODO: Split this shared gate into per-service gates after generating and
    # encrypting independent OIDC client and cookie secrets for every service.
    host.sso.oauth2ProxyGates.${gateName} = {
      displayName = "Media administration";
      inherit cookieName;
      allowedGroups = [ "media-admins" ];
      groupClaim = "media_groups";
      internalHttpsServiceNames = endpointNames;
      clearAuthorizationHeader = false;
      extraLocationsByName = logoutLocations;
    };
  };
}
