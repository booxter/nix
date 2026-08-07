{
  githubLogin,
  hostSpecs,
  lib,
  readPublicKey,
  username,
}:
let
  commonFeatures = [
    "benchmark"
    "big-parallel"
    "kvm"
  ];
  communityLinuxFeatures = commonFeatures ++ [ "nixos-test" ];
  managed = map (
    spec:
    let
      inherit (spec) builder;
      platformFeatures =
        if lib.hasSuffix "-linux" spec.platform then
          [ "nixos-test" ]
          ++ commonFeatures
          ++ [
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
      sshUser = username;
      systems = [ spec.platform ];
      supportedFeatures = platformFeatures;
      uses = [ "nix-build" ];
    }
  ) (builtins.filter (spec: spec ? builder) hostSpecs);
  community = [
    {
      name = "darwin-builder";
      pool = "community";
      sshHost = "darwin-build-box.nix-community.org";
      hostPublicKey = readPublicKey ../public-keys/hosts/nix-community-darwin-build-box.pub;
      sshUser = githubLogin;
      systems = [ "aarch64-darwin" ];
      maxJobs = 2;
      speedFactor = 20;
      supportedFeatures = [ "big-parallel" ];
      uses = [ "nixpkgs-review" ];
    }
    {
      name = "remote-linux-builder";
      pool = "community";
      sshHost = "aarch64-build-box.nix-community.org";
      hostPublicKey = readPublicKey ../public-keys/hosts/nix-community-aarch64-build-box.pub;
      sshUser = githubLogin;
      systems = [ "aarch64-linux" ];
      maxJobs = 10;
      speedFactor = 20;
      supportedFeatures = communityLinuxFeatures;
      uses = [ "nixpkgs-review" ];
    }
    {
      name = "remote-linux-x86-builder";
      pool = "community";
      sshHost = "build-box.nix-community.org";
      hostPublicKey = readPublicKey ../public-keys/hosts/nix-community-build-box.pub;
      sshUser = githubLogin;
      systems = [ "x86_64-linux" ];
      maxJobs = 5;
      speedFactor = 20;
      supportedFeatures = communityLinuxFeatures;
      uses = [ "nixpkgs-review" ];
    }
  ];
  definitions = managed ++ community;
  byUse =
    lib.genAttrs
      [
        "nix-build"
        "nixpkgs-review"
      ]
      (
        use:
        lib.groupBy (builder: builder.pool) (
          builtins.filter (builder: builtins.elem use builder.uses) definitions
        )
      );
in
{
  inherit byUse definitions;
}
