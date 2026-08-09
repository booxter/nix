{ sopsTools }:
let
  appSpec = import ../app-spec.nix;
in
{
  appSpecs = {
    "sops-bootstrap" =
      appSpec sopsTools "${sopsTools}/bin/sops-bootstrap"
        "Bootstrap host sops secrets and key recipients.";
    "sops-cat" = appSpec sopsTools "${sopsTools}/bin/sops-cat" "Decrypt and print a host secret.";
    "sops-edit" = appSpec sopsTools "${sopsTools}/bin/sops-edit" "Edit a host secret.";
    "sops-update" =
      appSpec sopsTools "${sopsTools}/bin/sops-update"
        "Merge missing template keys into a host secret.";
    "sops-copy" =
      appSpec sopsTools "${sopsTools}/bin/sops-copy"
        "Copy a top-level key path between host secrets.";
    "sops-set" =
      appSpec sopsTools "${sopsTools}/bin/sops-set"
        "Set a single host secret key path from stdin.";
    "sops-pass" =
      appSpec sopsTools "${sopsTools}/bin/sops-pass"
        "Hash and store a NixOS login password.";
  };
}
