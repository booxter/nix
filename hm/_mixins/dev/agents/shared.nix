{
  config,
  lib,
  osConfig,
}:
{
  context = builtins.readFile ./context.md;

  environment = {
    inherit (config.home.sessionVariables) SSH_ASKPASS;
    # Agent terminals must send SSH approval prompts to the graphical helper.
    SSH_ASKPASS_REQUIRE = "force";
  };

  skills = {
    simple-review = ./skills/simple-review;
    simple-review-nixpkgs = ./skills/simple-review-nixpkgs;
  }
  // lib.optionalAttrs (osConfig.host.realm == "work") {
    weekly-report = ./skills/weekly-report;
  };
}
