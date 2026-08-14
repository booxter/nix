{
  backupTopology,
  config,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit backupTopology config lib; };
  inherit (model)
    destination
    passwordSecretFor
    sources
    sshKeySecret
    ;
in
{
  config = lib.mkIf (sources != { } && destination != null && destination.transport == "sftp") {
    sops.secrets = {
      ${passwordSecretFor destination} = { };
      ${sshKeySecret} = {
        owner = destination.user;
        group = if destination.user == "root" then "root" else destination.user;
        mode = "0400";
      };
    };
  };
}
