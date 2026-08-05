pkgs: {
  darwin-lan-wan-bpf = pkgs.callPackage ./darwin-lan-wan-bpf { };

  fleet-cache-warmer = pkgs.callPackage ./fleet-cache-warmer { };

  ismc = pkgs.callPackage ./ismc { };
}
