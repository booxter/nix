{
  config,
  lib,
  ...
}:
let
  policyName = "media-admin";
  gateName = "srvarr-admin-apps";
  cookieName = "_srvarr_admin_sso";
  services = lib.filterAttrs (_: service: service.auth.policy == policyName) config.host.web.services;
  serviceNames = builtins.attrNames services;
  endpointNames = map (name: services.${name}.internal.endpointName) serviceNames;
  serviceHosts = lib.unique (
    lib.concatMap (
      name:
      let
        endpointName = services.${name}.internal.endpointName;
      in
      [
        services.${name}.internal.serverName
        endpointName
        "${endpointName}.local"
      ]
    ) serviceNames
  );
  originService = if serviceNames == [ ] then null else services.${builtins.head serviceNames};
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
    assertions = [
      {
        assertion = lib.all (name: services.${name}.internal != null) serviceNames;
        message = "The media-admin access policy requires internal HTTPS services";
      }
    ];

    host.sso.oauth2ProxyGates.${gateName} = {
      displayName = "Media administration";
      originLanding = "https://${originService.internal.serverName}/";
      inherit cookieName;
      allowedGroups = [ "media-admins" ];
      groupClaim = "media_groups";
      whitelistDomains = serviceHosts;
      internalHttpsServiceNames = endpointNames;
      authCookieVariableName = "auth_cookie";
      clearAuthorizationHeader = false;
      authRequestHeaders = [
        {
          variableName = "user";
          upstreamHeader = "x_auth_request_user";
          proxyHeader = "X-User";
        }
        {
          variableName = "email";
          upstreamHeader = "x_auth_request_email";
          proxyHeader = "X-Email";
        }
      ];
      extraLocationsByName = logoutLocations;
    };
  };
}
