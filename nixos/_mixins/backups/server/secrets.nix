{
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    cfg
    cloudGroup
    credentialedOffloads
    enabledOffloads
    offloadUser
    ;
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets =
      builtins.listToAttrs (
        lib.concatMap (name: [
          {
            name = cloudSecret name "localPassword";
            value = {
              owner = offloadUser name;
              group = offloadUser name;
              mode = "0400";
            };
          }
          {
            name = cloudSecret name "password";
            value = {
              owner = offloadUser name;
              group = offloadUser name;
              mode = "0400";
            };
          }
        ]) (builtins.attrNames enabledOffloads)
      )
      // lib.optionalAttrs (credentialedOffloads != { }) {
        ${applicationKeyIdSecret} = {
          group = cloudGroup;
          mode = "0440";
        };
        ${applicationKeySecret} = {
          group = cloudGroup;
          mode = "0440";
        };
      };
  };
}
