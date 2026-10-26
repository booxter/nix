{ lib, osConfig }:
{
  context = builtins.readFile ./context.md;

  skills = {
    simple-review = ./skills/simple-review;
    simple-review-nixpkgs = ./skills/simple-review-nixpkgs;
  }
  // lib.optionalAttrs (osConfig.host.realm == "work") {
    weekly-report = ./skills/weekly-report;
  };
}
