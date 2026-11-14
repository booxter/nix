{ lib }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
  yubikeys = import ../yubikeys.nix;
  keys = lib.mapAttrs (_: readPublicKey) {
    frameBuilder = ./public-keys/frame-builder.pub;
    mairBuilder = ./public-keys/mair-builder.pub;
    mairSecretive = ./public-keys/mair-secretive.pub;
    mminiBuilder = ./public-keys/mmini-builder.pub;
    workLaptop = ./public-keys/jgwxhwdl4x.pub;
    workBuilder = ./public-keys/jgwxhwdl4x-nix-builder.pub;
    yubikey = yubikeys.home.main.sshPublicKey;
    workYubikeyMain = yubikeys.work.main.sshPublicKey;
    workYubikeyLaptop = yubikeys.work.laptop.sshPublicKey;
    fleetUserCa = ./public-keys/fleet-user-ca.pub;
    ciBuilder = ./public-keys/nix-ci-builder.pub;
  };
  # Sudo accepts only hardware identities belonging to the destination's realm.
  sudo = {
    home = [
      keys.mairSecretive
      keys.yubikey
    ];
    work = [
      keys.workYubikeyMain
      keys.workYubikeyLaptop
    ];
  };
in
{
  inherit keys sudo;
  hardware = lib.concatLists (builtins.attrValues sudo);

  builders = {
    frame = keys.frameBuilder;
    mair = keys.mairBuilder;
    mmini = keys.mminiBuilder;
    ci = keys.ciBuilder;
  };

  operators = {
    JGWXHWDL4X = [
      keys.workLaptop
      keys.workBuilder
      keys.workYubikeyMain
      keys.workYubikeyLaptop
    ];
    frame = [ keys.yubikey ];
    mair = [ keys.mairSecretive ];
    mmini = [ keys.yubikey ];
  };
  ticketIssuers = {
    frame = keys.yubikey;
    mair = keys.fleetUserCa;
    mmini = keys.yubikey;
  };
}
