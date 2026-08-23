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
        "kubernetes-helmPlugins.helm-unittest"
        "llama-cpp"
        "openapi-generator-cli"
        "openvswitch"
        "openvswitch-dpdk"
        "ovn"
        "podman-desktop"
        "python3Packages.llama-cpp-python"
        "python3Packages.lm-eval"
        "python3Packages.mailbits"
        "python3Packages.mlx"
        "python3Packages.pypdfium2"
        "python3Packages.pypi-simple"
        "python3Packages.semchunk"
        "python3Packages.tqdm-multiprocess"
        "python3Packages.word2number"
        "quartz-wm"
        "ramalama"
        "xclock"
      ];
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
    };
  };
}
