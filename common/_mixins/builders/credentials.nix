{
  config,
  fleetInventory,
  lib,
  system,
  ...
}:
let
  homeRealm = config.host.realm == "home";
  client = homeRealm && config.host.nix.builderClient != null;
  participant = client || (homeRealm && config.host.nix.builder != null);
  signingSecret = "nix/store_signing_key";
  sshSecret = "nix/builder_private_key";
in
{
  config = lib.mkIf participant (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = builtins.hasAttr config.networking.hostName fleetInventory.builderSigningKeys;
            message = "Home builder participants need a public store-signing key in inventory.";
          }
        ];

        sops.secrets = {
          ${signingSecret} = {
            mode = "0400";
            owner = "root";
          };
          ${sshSecret} = lib.mkIf client {
            mode = "0400";
            owner = "root";
          };
        };

        # The daemon signs its build outputs. The SSH account cannot read the key
        # or sign arbitrary imported paths on the daemon's behalf.
        nix.settings.secret-key-files = [ config.sops.secrets.${signingSecret}.path ];
      }
      (lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        sops.secrets.${signingSecret}.restartUnits = [ "nix-daemon.service" ];
        systemd.services.nix-daemon = {
          requires = [ "sops-install-secrets.service" ];
          after = [ "sops-install-secrets.service" ];
        };
      })
    ]
  );
}
