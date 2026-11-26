{
  lib,
  callPackage,
  openssh,
  replaceVars,
  fleetInventory,
}:
let
  keys = lib.concatLists (
    lib.mapAttrsToList (
      _: keys: builtins.attrValues (lib.filterAttrs (_: key: key ? sshPublicKey) keys)
    ) fleetInventory.yubikeys
  );
  identities = map (key: {
    inherit (key) serial;
    public_key = builtins.readFile key.sshPublicKey;
  }) keys;
  # These models require a PIN for verification; biometric keys may need touch first.
  pinFirstKeys = builtins.filter (
    key:
    builtins.elem key.model [
      "YubiKey 5C Nano"
      "YubiKey 5C NFC"
    ]
  ) keys;
  # Substitution must preserve the patch's line counts.
  pinFirstBlobs = lib.concatMapStrings (
    key:
    builtins.toJSON (builtins.elemAt (lib.splitString " " (builtins.readFile key.sshPublicKey)) 1)
    + ", "
  ) pinFirstKeys;
  resolver = callPackage ./ssh-device { inherit identities openssh; };
in
openssh.overrideAttrs (old: {
  pname = "openssh-yubikey";
  patches = (old.patches or [ ]) ++ [
    # General agent fix; independent of the inventory and suitable for upstream.
    ../../patches/openssh-restore-touch-prompt-after-pin.patch
    # Local policy: resolve mapped keys and defer prompts for PIN-only models.
    (replaceVars ../../patches/openssh-resolve-signing-device.patch { inherit resolver; })
    (replaceVars ../../patches/openssh-prompt-for-pin-before-touch.patch {
      public_keys = pinFirstBlobs;
    })
  ];
  passthru = (old.passthru or { }) // {
    inherit resolver;
  };
})
