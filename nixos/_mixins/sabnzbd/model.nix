{
  config,
  lib,
  outputs,
}:
let
  cfg = config.host.sabnzbd;
  claim = config.host.storage.claims.${cfg.storage.claim} or null;
  storageResource =
    if claim == null then
      null
    else
      outputs.nixosConfigurations.${claim.provider}.config.host.storage.resources.${claim.resource}
        or null;
  account = config.host.accounts.users.${cfg.user} or null;
  vpnNamespace = config.host.vpn.namespaces.${cfg.vpn.namespace} or null;
  baseDir = if claim == null then null else "${claim.mountPoint}/${cfg.storage.relativePath}";
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
    displayname = server.displayName;
    inherit (server)
      connections
      enable
      host
      port
      priority
      required
      timeout
      ;
    ssl = server.tls.enable;
    ssl_verify = server.tls.verify;
    ssl_ciphers = "";
    optional = false;
    pipelining_requests = 1;
    retention = 0;
    expire_date = "";
    quota = "";
    usage_at_start = 0;
    notes = "";
  };
in
{
  inherit
    account
    baseDir
    cfg
    claim
    routeCategories
    routes
    vpnNamespace
    ;
  completeDir = if baseDir == null then null else "${baseDir}/manual";
  watchDir = if baseDir == null then null else "${baseDir}/watch";
  incompleteDir = if baseDir == null then null else "${baseDir}/.incomplete";
  storageGroup = if storageResource == null then null else storageResource.sharedGroup;
  servers = lib.mapAttrs renderServer cfg.servers;
  ready = claim != null && account != null && vpnNamespace != null;
}
