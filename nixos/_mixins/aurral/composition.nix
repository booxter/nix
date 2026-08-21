{
  imports = [
    ../../../common/_mixins/hardware
    ../../../common/_mixins/host/options.nix
    ../../../common/_mixins/network
    ../../../common/_mixins/site/options.nix
    ../auto-upgrade/options.nix
    ../backups/client/options.nix
    ../site-ip/options.nix
    ../sso/directory.nix
    ../sso/oidc.nix
    ../sso/provider-options.nix
    ../storage/resources
    ../storage/volumes/options.nix
    ../vpn
    ../web/options.nix
    ./.
  ];

  _module.args.storageIdentities = import ../storage/identities.nix;
}
