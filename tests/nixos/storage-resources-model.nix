{ pkgs, ... }:
let
  inherit (pkgs) lib;
  config = {
    networking.hostName = "consumer-node";
    host = {
      accounts = {
        groups = { };
        users = { };
      };
      storage = {
        claims.media = {
          provider = "provider-node";
          resource = "media";
          mountPoint = "/srv/media";
          directories = { };
          attachments = {
            indexer.unit = "media-indexer";
            player.unit = "media-player";
          };
        };
        resources = { };
        volumes = { };
      };
    };
  };
  outputs = {
    nixosConfigurations.provider-node.config.host.storage = {
      claims = { };
      resources.media = {
        volume = "bulk";
        relativePath = "library";
        sharedGroup = null;
        directoryDefaults = {
          owner = "root";
          group = "root";
          mode = "0755";
          enforce = false;
        };
        directories = { };
        identities = {
          groups = [ ];
          users = [ ];
        };
        nfs = {
          enable = true;
          fsid = 10;
          anonymousIdentity = null;
        };
      };
      volumes.bulk.mountPoint = "/srv/storage";
    };
  };
  model = import ../../nixos/_mixins/storage/resources/model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
assert
  map (attachment: attachment.unit) model.localAttachments == [
    "media-indexer"
    "media-player"
  ];
assert lib.all (attachment: attachment.mountPoint == "/srv/media") model.localAttachments;
pkgs.runCommand "storage-resources-model-test" { } ''
  touch "$out"
''
