{
  home.main = {
    model = "YubiKey 5C Nano";
    serial = "35640926";
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
