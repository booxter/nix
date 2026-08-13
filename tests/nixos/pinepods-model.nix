{ pkgs, ... }:
let
  inherit (pkgs) lib;
  config = {
    networking.hostName = "podcast-node";
    host = {
      accounts = {
        groups.shared.gid = 400;
        users.pinepods.uid = 401;
      };
      pinepods = {
        storage = {
          claim = "podcasts";
          relativePath = "downloads/pinepods";
        };
        sso.application = "podcast-listeners";
      };
      storage = {
        claims.podcasts = {
          provider = "podcast-node";
          resource = "podcasts";
          mountPoint = "/srv/podcasts";
        };
        resources.podcasts = {
          volume = "durable";
          sharedGroup = "shared";
        };
        volumes.durable.mountPoint = "/srv/durable";
      };
      sso = {
        applications.podcast-listeners = {
          adminGroup = "podcast-admins";
          userGroup = "podcast-users";
          bootstrapOwner = "owner";
        };
        users.owner = {
          displayName = "Test Owner";
          mailAddressSopsKey = "directory/users/owner/mail";
          groups = [
            "podcast-admins"
            "podcast-users"
          ];
        };
        oidc = {
          baseScopes = [ "openid" ];
          clients.pinepods.clientId = "pinepods";
        };
      };
      web.services.pinepods.public.url = "https://podcasts.example.invalid";
    };
  };
  facts.oci-images.pinepods = {
    image = "example.invalid/pinepods";
    digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    hash = lib.fakeHash;
    tag = "1.0.0";
  };
  outputs.nixosConfigurations = { };
  model = import ../../nixos/_mixins/pinepods/model.nix {
    inherit
      config
      facts
      lib
      outputs
      pkgs
      ;
  };
in
assert model.downloadsDir == "/srv/podcasts/downloads/pinepods";
assert model.storageGroup == "shared";
assert model.bootstrapOwnerName == "owner";
assert model.bootstrapOwner.mailAddressSopsKey == "directory/users/owner/mail";
assert model.ssoApplication.adminGroup == "podcast-admins";
pkgs.runCommand "pinepods-model-test" { } ''
  touch "$out"
''
