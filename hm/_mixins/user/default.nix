{ config, lib, ... }:
let
  userType = lib.types.submodule {
    options = {
      fullName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Full name associated with the user identity.";
      };

      email = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Email address associated with the user identity.";
      };
    };
  };
in
{
  options.host.hm.user = lib.mkOption {
    type = lib.types.attrsOf userType;
    default = { };
    description = "Named user identities available to Home Manager modules.";
  };

  config.host.hm.user = {
    personal = {
      fullName = "Ihar Hrachyshka";
      email = "ihar.hrachyshka@gmail.com";
    };
    nvidia = {
      fullName = "Ihar Hrachyshka";
      email = "${config.home.username}@nvidia.com";
    };
  };
}
