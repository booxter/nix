pkgs: {
  darwin-lan-wan-bpf = pkgs.callPackage ./darwin-lan-wan-bpf { };

  fleet-cache-warmer = pkgs.callPackage ./fleet-cache-warmer { };

  fleet-cache-warmer-work = pkgs.callPackage ./fleet-cache-warmer {
    name = "fleet-cache-warmer-work";
    packageAttrName = "fleet-cache-warmer-work";
    pushToAttic = false;
    targetFilter = "work";
  };

  ismc = pkgs.callPackage ./ismc { };
}
