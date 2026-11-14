{
  home.main = {
    model = "YubiKey 5C Nano";
    serial = "35640926";
    sshPublicKey = ./ssh/public-keys/yubikey.pub;
    ageIdentity = ./age/home-main.txt;
    openpgp = {
      publicKey = ./openpgp/home-main.asc;
      fingerprint = "9A69C4E63FB9053D2E404BDD589400D6A9793DDD";
      encryptionFingerprint = "6B897B6CC45E0692192C4C386853A85DEC000BEB";
    };
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

  home.nfc = {
    model = "YubiKey 5C NFC";
    serial = "31341726";
    openpgp = {
      publicKey = ./openpgp/home-nfc.asc;
      fingerprint = "C7B35E86998DC4F54D19CBEB25CF345EE4DD440F";
      encryptionFingerprint = "DCD8DAAF0BF657D21253D2AED6543BA0E885CCDB";
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
