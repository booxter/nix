{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  app = model.ssoApplication;
  accessGroups = builtins.filter (group: group != null) [
    (if app == null then null else app.adminGroup)
    (if app == null then null else app.userGroup)
  ];
  groupScopes = lib.genAttrs accessGroups (_: model.oidcScopes ++ [ "shelfmark_groups" ]);
  groupClaims = lib.genAttrs accessGroups (group: [ group ]);
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.shelfmark.auth = {
      mode = "oidc";
      oidcRegistration = {
        displayName = "Shelfmark";
        originUrls = [ "${model.shelfmarkService.public.url}/api/auth/oidc/callback" ];
        originLanding = "${model.shelfmarkService.public.url}/";
        scopeMaps = groupScopes;
        claimMaps.shelfmark_groups.valuesByGroup = groupClaims;
        secret = {
          sopsKey = "shelfmark/oidc/client_secret";
          name = "shelfmark/oidc/client_secret";
          restartUnits = [ "shelfmark.service" ];
        };
      };
    };
  };
}
