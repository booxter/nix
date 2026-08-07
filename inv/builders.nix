{ hostSpecs, lib }:
let
  managed = map (
    spec:
    let
      inherit (spec) builder;
      supportsNspawnTests = builder.supportsNspawnTests or false;
      platformFeatures =
        if lib.hasSuffix "-linux" spec.platform then
          [
            "nixos-test"
            "benchmark"
            "big-parallel"
            "kvm"
          ]
        else
          [ "big-parallel" ];
    in
    {
      inherit (spec) name;
      inherit (builder) pool;
      inherit supportsNspawnTests;
      maxJobs = builder.maxJobs or 4;
      speedFactor = builder.speedFactor or 100;
      sshHost = builder.sshHost or spec.name;
      systems = [ spec.platform ];
      supportedFeatures =
        builder.supportedFeatures or (
          platformFeatures
          ++ lib.optionals supportsNspawnTests [
            "devnet"
            "uid-range"
          ]
        );
    }
  ) (builtins.filter (spec: spec ? builder) hostSpecs);
in
{
  inherit managed;
  byPool = lib.groupBy (builder: builder.pool) managed;
}
