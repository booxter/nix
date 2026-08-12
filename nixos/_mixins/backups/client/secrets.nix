{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    activeDestinations
    passwordSecretFor
    sources
    sshKeySecretFor
    ;
in
{
  config = lib.mkIf (sources != { }) {
    sops.secrets = lib.mkMerge (
      lib.mapAttrsToList (
        name: destination:
        lib.optionalAttrs (destination.transport == "sftp") {
          ${passwordSecretFor name destination} = { };
          ${sshKeySecretFor name} = {
            owner = destination.user;
            group = if destination.user == "root" then "root" else destination.user;
            mode = "0400";
          };
        }
      ) activeDestinations
    );
  };
}
