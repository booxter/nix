{
  backupTopology,
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit backupTopology config lib; };
  inherit (model)
    cloudGroup
    credentialedOffloads
    enabledOffloads
    offloadUser
    server
    ;
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
in
{
  config = lib.mkIf (server != null) {
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
