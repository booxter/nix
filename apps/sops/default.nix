{ sopsTools }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };
in
{
  "sops-bootstrap" =
    mkApp "${sopsTools}/bin/sops-bootstrap" "Bootstrap host sops secrets and key recipients.";
  "sops-cat" = mkApp "${sopsTools}/bin/sops-cat" "Decrypt and print a host secret.";
  "sops-edit" = mkApp "${sopsTools}/bin/sops-edit" "Edit a host secret.";
  "sops-update" =
    mkApp "${sopsTools}/bin/sops-update" "Merge missing template keys into a host secret.";
  "sops-copy" = mkApp "${sopsTools}/bin/sops-copy" "Copy a top-level key path between host secrets.";
  "sops-set" = mkApp "${sopsTools}/bin/sops-set" "Set a single host secret key path from stdin.";
  "sops-ups-sync" =
    mkApp "${sopsTools}/bin/sops-ups-sync" "Sync NUT UPS server passwords into client secrets.";
  "sops-pass" = mkApp "${sopsTools}/bin/sops-pass" "Hash and store a NixOS login password.";
}
