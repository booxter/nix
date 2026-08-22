{ lib }:
let
  baseFeatures = [
    "benchmark"
    "big-parallel"
    "kvm"
    "nixos-test"
  ];
  linuxFeatures = [
    "devnet"
    "uid-range"
  ];
  builder =
    {
      hostName,
      maxJobs ? 4,
      realm ? "home",
      speedFactor ? 100,
      system ? "x86_64-linux",
      supportedFeatures ? baseFeatures ++ lib.optionals (lib.hasSuffix "-linux" system) linuxFeatures,
      uses ? [
        "build"
        "nixpkgs"
      ],
    }:
    {
      inherit
        hostName
        maxJobs
        realm
        speedFactor
        supportedFeatures
        system
        uses
        ;
    };
in
{
  builder1 = builder {
    hostName = "builder1";
    maxJobs = 2;
  };
  builder2 = builder {
    hostName = "builder2";
    maxJobs = 2;
  };
  builder3 = builder {
    hostName = "builder3";
    maxJobs = 2;
  };
  frame = builder {
    hostName = "frame";
    speedFactor = 200;
  };
  mmini = builder {
    hostName = "mmini";
    system = "aarch64-darwin";
  };
  nvws = builder {
    hostName = "nvws.local";
    realm = "work";
  };
}
