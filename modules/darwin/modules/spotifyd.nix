{ pkgs, ... }: {
  enable = true;
  package = (pkgs.spotifyd.override { withKeyring = true; });
  settings = {
    global = {
      # security add-generic-password -s spotifyd -D rust-keyring -a <your username> -w <your password>
      username = "11126800926";
      use_keyring = true;
      device_name = "nix";
      device_type = "computer";
    };
  };
}
