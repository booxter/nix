{
  imports = [
    ./btrfs
    ./resources
    ./volumes
  ];

  _module.args.storageIdentities = import ./identities.nix;
}
