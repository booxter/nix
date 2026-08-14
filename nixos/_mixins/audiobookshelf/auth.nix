{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  app = model.ssoApplication;
  accessGroups = builtins.filter (group: group != null) [
    (if app == null then null else app.adminGroup)
    (if app == null then null else app.userGroup)
  ];
  groupScopes = lib.genAttrs accessGroups (_: model.oidcScopes ++ [ "abs_groups" ]);
  groupClaims =
    lib.optionalAttrs (app != null && app.adminGroup != null) {
      ${app.adminGroup} = [ "admin" ];
    }
    // lib.optionalAttrs (app != null && app.userGroup != null) {
      ${app.userGroup} = [ "user" ];
    };
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.audiobookshelf.auth = {
      mode = "oidc";
      oidcRegistration = {
        displayName = "Audiobookshelf";
        originUrls = [
          "${model.service.public.url}/auth/openid/callback"
          "${model.service.public.url}/auth/openid/mobile-redirect"
        ];
        originLanding = "${model.service.public.url}/";
        scopeMaps = groupScopes;
        claimMaps.abs_groups.valuesByGroup = groupClaims;
        secret = {
          sopsKey = "audiobookshelf/oidc/client_secret";
          name = "audiobookshelf/oidc/client_secret";
          restartUnits = [ "audiobookshelf-reconcile.service" ];
        };
      };
    };
  };
}
