{
  config,
  pkgs,
  storageModel,
}:
let
  cfg = config.host.pinepods;
  claim = storageModel.localClaims.${cfg.storage.claim} or null;
  ssoApplication = config.host.sso.applications.${cfg.sso.application} or null;
  bootstrapOwnerName = if ssoApplication == null then null else ssoApplication.bootstrapOwner;
  bootstrapOwner =
    if bootstrapOwnerName == null then null else config.host.sso.users.${bootstrapOwnerName} or null;
  containerImage = import ../../_lib/oci-image.nix {
    image = cfg.container;
    inherit pkgs;
  };
in
{
  inherit
    bootstrapOwner
    bootstrapOwnerName
    cfg
    claim
    ssoApplication
    ;
  downloadsDir = if claim == null then null else "${claim.mountPoint}/${cfg.storage.relativePath}";
  storageGroup =
    if claim == null || claim.resolvedResource.directoryDefaults.group == "root" then
      null
    else
      claim.resolvedResource.directoryDefaults.group;
  service = config.host.web.services.pinepods;
  oidcClient = config.host.sso.oidc.clients.pinepods or null;
  oidcScopes = config.host.sso.oidc.baseScopes;
  image = containerImage.ref;
  inherit (containerImage) imageFile;
  bootstrapReady =
    bootstrapOwner != null
    && bootstrapOwner.mailAddressSopsKey != null
    && ssoApplication.roles ? admin
    && ssoApplication.roles ? user;
}
