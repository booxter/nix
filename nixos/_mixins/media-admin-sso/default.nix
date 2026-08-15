{
  lib,
  webModel,
  ...
}:
let
  policyName = "media-admin";
  gateName = "srvarr-admin-apps";
  services = lib.filterAttrs (
    _: service: service.auth.policy == policyName
  ) webModel.normalizedInternalServices;
  endpointNames = map (service: service.internal.endpointName) (builtins.attrValues services);
in
{
  config = lib.mkIf (services != { }) {
    # TODO: Split this shared gate into per-service gates after generating and
    # encrypting independent OIDC client and cookie secrets for every service.
    host.sso.oauth2ProxyGates.${gateName} = {
      displayName = "Media administration";
      allowedGroups = [ "media-admins" ];
      groupClaim = "media_groups";
      internalHttpsServiceNames = endpointNames;
      clearAuthorizationHeader = false;
    };
  };
}
