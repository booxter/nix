{ sopsTools }:
let
  appSpec = import ../app-spec.nix;
in
{
  appSpecs = {
    "sops-bootstrap" =
      appSpec "${sopsTools}/bin/sops-bootstrap" "Bootstrap host sops secrets and key recipients.";
    "sops-cat" = appSpec "${sopsTools}/bin/sops-cat" "Decrypt and print a host secret.";
    "sops-edit" = appSpec "${sopsTools}/bin/sops-edit" "Edit a host secret.";
    "sops-update" =
      appSpec "${sopsTools}/bin/sops-update" "Merge missing template keys into a host secret.";
    "sops-copy" =
      appSpec "${sopsTools}/bin/sops-copy" "Copy a top-level key path between host secrets.";
    "sops-set" = appSpec "${sopsTools}/bin/sops-set" "Set a single host secret key path from stdin.";
    "sops-ups-sync" =
      appSpec "${sopsTools}/bin/sops-ups-sync" "Sync NUT UPS server passwords into client secrets.";
    "sops-pass" = appSpec "${sopsTools}/bin/sops-pass" "Hash and store a NixOS login password.";
  };
}
