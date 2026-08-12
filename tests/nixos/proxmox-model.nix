{ pkgs, ... }:
let
  inherit (pkgs) lib;
  model = (import ../../nixos/_mixins/proxmox/lib.nix { inherit lib; }).build {
    node-a = {
      cluster = "test-cluster";
      controller = true;
      isGuest = false;
      isNode = true;
      realm = "test-realm";
    };
    node-b = {
      cluster = "test-cluster";
      controller = false;
      isGuest = false;
      isNode = true;
      realm = "test-realm";
    };
    guest-a = {
      cluster = "test-cluster";
      controller = false;
      isGuest = true;
      isNode = false;
      realm = "test-realm";
    };
  };
in
assert model.controllersByRealmCluster.test-realm.test-cluster == [ "node-a" ];
assert
  model.guestNodes.guest-a == [
    "node-a"
    "node-b"
  ];
pkgs.runCommand "proxmox-model-test" { } ''
  touch "$out"
''
