{ lib }:
lib.types.submodule {
  options = {
    hostname = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Dynamic DNS hostname to update.";
    };

    username = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Dynamic DNS account username.";
    };
  };
}
