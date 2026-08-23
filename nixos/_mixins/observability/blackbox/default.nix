{
  imports = [
    ../../../../common/_mixins/hardware
    ../../../../common/_mixins/host/options.nix
    ../../../../common/_mixins/internal-pki
    ../../../../common/_mixins/network
    ../../../../common/_mixins/observability/policy.nix
    ../blackbox.nix
    ../prometheus-endpoints.nix
  ];
}
