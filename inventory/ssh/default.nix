{ lib }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
  keys = lib.mapAttrs (_: readPublicKey) {
    frame = ./public-keys/frame.pub;
    mair = ./public-keys/mair.pub;
    mairSecretive = ./public-keys/mair-secretive.pub;
    mmini = ./public-keys/mmini.pub;
    workLaptop = ./public-keys/jgwxhwdl4x.pub;
    workBuilder = ./public-keys/jgwxhwdl4x-nix-builder.pub;
    yubikey = ./public-keys/yubikey.pub;
    fleetUserCa = ./public-keys/fleet-user-ca.pub;
    ciBuilder = ./public-keys/nix-ci-builder.pub;
  };
  hardware = [
    keys.mairSecretive
    keys.yubikey
  ];
in
{
  inherit keys hardware;

  operators = {
    JGWXHWDL4X = [
      keys.workLaptop
      keys.workBuilder
    ];
    frame = [
      keys.frame
      keys.yubikey
    ];
    mair = [
      keys.mair
      keys.mairSecretive
    ];
    mmini = [
      keys.mmini
      keys.yubikey
    ];
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
