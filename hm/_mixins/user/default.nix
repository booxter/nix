{
  lib,
  osConfig,
  ...
}:
let
  defaultHomePage = "https://dash.${osConfig.host.network.publicDomain}";
in
{
  options.host.hm = {
    fullName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Full name of the Home Manager user.";
    };

    email = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Email address of the Home Manager user.";
    };

    homePage = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = defaultHomePage;
      description = "Default browser home page of the Home Manager user.";
    };

    numberedWorkspaces = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = 4;
      description = "Default number of numbered desktop workspaces.";
    };
  };
}
