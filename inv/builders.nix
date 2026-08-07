{ hostSpecs, lib }:
let
  managed = map (
    spec:
    let
      inherit (spec) builder;
      platformFeatures =
        if lib.hasSuffix "-linux" spec.platform then
          [
            "nixos-test"
            "benchmark"
            "big-parallel"
            "kvm"
            "devnet"
            "uid-range"
          ]
        else
          [ "big-parallel" ];
    in
    {
      inherit (spec) name;
      inherit (builder) pool;
      maxJobs = builder.maxJobs or 4;
      speedFactor = builder.speedFactor or 100;
      sshHost = builder.sshHost or spec.name;
      systems = [ spec.platform ];
      supportedFeatures = platformFeatures;
    }
  ) (builtins.filter (spec: spec ? builder) hostSpecs);
in
{
  inherit managed;
  byPool = lib.groupBy (builder: builder.pool) managed;
}
