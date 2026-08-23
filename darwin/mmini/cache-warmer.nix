{
  host.nix.cacheWarmer = {
    builderMaxJobs = {
      builder1 = 1;
      builder2 = 1;
      builder3 = 1;
    };

    fleet.enable = true;

    nixpkgs = {
      enable = true;
      branches = [ "master" ];
      packages = [
        "elfdeps"
        "fromager"
        "gpauth"
        "gpclient"
        "helm-unittest"
        "llama-cpp"
        "llama-cpp-python"
        "lm-eval"
        "mailbits"
        "mlx"
        "openapi-generator-cli"
        "openvswitch"
        "openvswitch-dpdk"
        "ovn"
        "podman-desktop"
        "pypdfium2"
        "pypi-simple"
        "quartz-wm"
        "ramalama"
        "semchunk"
        "tqdm-multiprocess"
        "word2number"
        "xclock"
      ];
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
    };
  };
}
