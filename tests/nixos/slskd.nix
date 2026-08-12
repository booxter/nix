{ pkgs, ... }:
let
  inherit (pkgs) lib;
  instance =
    {
      apiPort,
      peerPort,
      relativePath,
      secretPrefix,
      stateDir,
    }:
    {
      enable = true;
      api.port = apiPort;
      package = pkgs.slskd;
      inherit secretPrefix stateDir;
      settings = { };
      storage = {
        claim = "downloads";
        inherit relativePath;
      };
      vpn = {
        namespace = "private";
        inherit peerPort;
      };
    };
  config = {
    host = {
      aurral.slskd = {
        enable = true;
        instance = "primary";
        priority = 20;
        preferredFormat = "flac";
        strictFormat = true;
        cleanupAfterRuns = true;
      };
      slskd = {
        user = "download-user";
        group = "download-group";
        instances = {
          primary = instance {
            apiPort = 5030;
            peerPort = 15030;
            relativePath = "slskd/primary";
            secretPrefix = "slskd/primary";
            stateDir = "/var/lib/slskd/primary";
          };
          secondary = instance {
            apiPort = 5031;
            peerPort = 15031;
            relativePath = "slskd/secondary";
            secretPrefix = "slskd/secondary";
            stateDir = "/var/lib/slskd/secondary";
          };
        };
      };
      storage.claims.downloads.mountPoint = "/srv/downloads";
      vpn.namespaces.private = {
        bridgeAddress = "192.0.2.1";
        namespaceAddress = "192.0.2.2";
      };
    };
  };
  model = import ../../nixos/_mixins/slskd/model.nix { inherit config lib; };
  aurralModel = import ../../nixos/_mixins/aurral/model.nix { inherit config lib; };
in
assert
  builtins.attrNames model.resolved == [
    "primary"
    "secondary"
  ];
assert model.resolved.primary.unitName == "slskd-primary";
assert model.resolved.secondary.apiUrl == "http://192.0.2.2:5031";
assert model.resolved.secondary.completedDir == "/srv/downloads/slskd/secondary/complete";
assert
  model.apiBindings == [
    "private:5030"
    "private:5031"
  ];
assert
  model.peerBindings == [
    "private:15030"
    "private:15031"
  ];
assert aurralModel.selected.unitName == "slskd-primary";
assert aurralModel.selected.completedDir == "/srv/downloads/slskd/primary/complete";
pkgs.runCommand "slskd-model-test" { } ''
  touch "$out"
''
