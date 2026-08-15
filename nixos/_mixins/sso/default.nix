{
  imports = [
    ./directory.nix
    ./provider-options.nix
    ./provider
    ./oidc.nix
    ./oauth2-proxy-gate.nix
    ./oauth2-proxy-gate/session-store
  ];
}
