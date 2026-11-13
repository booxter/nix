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
    yubikey = ./public-keys/yubikey.pub;
    workYubikeyMain = yubikeys.work.main.sshPublicKey;
    workYubikeyLaptop = yubikeys.work.laptop.sshPublicKey;
    fleetUserCa = ./public-keys/fleet-user-ca.pub;
    ciBuilder = ./public-keys/nix-ci-builder.pub;
  };
  hardware = [
    keys.mairSecretive
    keys.yubikey
    keys.workYubikeyMain
    keys.workYubikeyLaptop
  ];
in
{
  inherit keys hardware;

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

  # Sudo accepts the operator's hardware identities, not software fallback
  # keys or the fleet CA. These identities apply across the operator's realms.
  sudo = hardware;
}
