{
  config,
  lib,
  storageIdentities ? import ../storage/identities.nix,
  storageModel,
}:
let
  cfg = config.host.sabnzbd;
  claim = storageModel.localClaims.media or null;
  storageResource = if claim == null then null else claim.resolvedResource;
  identity = storageIdentities.users.sabnzbd or null;
  vpnNamespace = config.host.vpn.namespaces.wg or null;
  downloadModel = import ../downloads/model.nix { inherit config lib; };
  routes = lib.filterAttrs (_: route: route.clientName == "sabnzbd") downloadModel.routes;
  routeCategories = lib.mapAttrs' (
    _: route:
    lib.nameValuePair route.category {
      name = route.category;
      order = 50;
      pp = "";
      script = "Default";
      dir = route.path;
      newzbin = "";
      priority = -100;
    }
  ) routes;
  renderServer = name: server: {
    inherit name;
    displayname = name;
    host = name;
    inherit (server)
      connections
      enable
      priority
      required
      timeout
      ;
    pipelining_requests = 2;
    ssl_verify = server.tlsVerification;
  };
in
{
  inherit
    cfg
    claim
    identity
    routeCategories
    vpnNamespace
    ;
  port = 6336;
  storageGroup =
    if storageResource == null || storageResource.directoryDefaults.group == "root" then
      null
    else
      storageResource.directoryDefaults.group;
  servers = lib.mapAttrs renderServer cfg.servers;
  ready = claim != null && identity != null && vpnNamespace != null;
}
