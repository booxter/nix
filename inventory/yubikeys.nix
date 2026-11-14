{
  home.main = {
    model = "YubiKey 5C Nano";
    serial = "35640926";
    sshPublicKey = ./ssh/public-keys/yubikey.pub;
    ageIdentity = ./age/home-main.txt;
  };

  home.laptop = {
    model = "YubiKey 5C Nano";
    serial = "38418581";
    openpgp = {
      publicKey = ./openpgp/home-laptop.asc;
      fingerprint = "5E99D5F16F5636F260F413CAB2390EBD1D0A6338";
      encryptionFingerprint = "25AC90145B9FEAA32881EC3066DA79073C0D566F";
    };
  };

  work = {
    main = {
      model = "YubiKey 5C Nano";
      serial = "32147445";
      sshPublicKey = ./ssh/public-keys/yubikey-work-main.pub;
      ageIdentity = ./age/work-main.txt;
    };

    laptop = {
      model = "YubiKey 5C Nano";
      serial = "32147427";
      sshPublicKey = ./ssh/public-keys/yubikey-work-laptop.pub;
      ageIdentity = ./age/work-laptop.txt;
    };
  };
}
