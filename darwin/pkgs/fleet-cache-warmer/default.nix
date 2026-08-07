{
  lib,
  attic-client,
  clippy,
  nix,
  pushToAttic ? true,
  rustfmt,
  rustPlatform,
  targetRealm,
}:

let
  inventory = builtins.fromJSON (builtins.readFile ../../../ci/ci-target-inventory.json);
  hostInventory = import ../../../inv { inherit lib; };
  realm = hostInventory.realms.${targetRealm};
  hostForTarget =
    target:
    let
      match = builtins.match "(nixos|darwin)Configurations\\.([^.]+)\\..*" target.attr;
    in
    if match == null then null else builtins.elemAt match 1;
  matchesTargetFilter =
    target:
    let
      host = hostForTarget target;
    in
    if host == null then
      realm.build.includeUnscopedCiTargets or false
    else
      hostInventory.hostSpecsByName.${host}.realm == targetRealm;
  ciValidatedWarmTargets = map (target: target.attr) (
    lib.filter (target: target.warm && matchesTargetFilter target) (
      inventory.buildTargets ++ inventory.regularChecks
    )
  );
in
rustPlatform.buildRustPackage {
  pname = "fleet-cache-warmer";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
    ];
  };

  cargoHash = "sha256-BS46DRuN9fU1vQBWKuHtG47l8n/mjKJR5WhOZltJ4Ao=";

  FLEET_CACHE_WARMER_ATTIC = lib.optionalString pushToAttic (lib.getExe attic-client);
  FLEET_CACHE_WARMER_NIX = lib.getExe nix;
  FLEET_CACHE_WARMER_PUSH_TO_ATTIC = builtins.toJSON pushToAttic;
  FLEET_CACHE_WARMER_TARGETS_JSON = builtins.toJSON ciValidatedWarmTargets;

  nativeCheckInputs = [
    clippy
    rustfmt
  ];

  preCheck = ''
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
  '';
  cargoTestFlags = [ "--all-targets" ];

  passthru.ciWarmTargets = ciValidatedWarmTargets;

  meta = {
    description = "Build CI-validated fleet outputs and optionally push them to Attic";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "fleet-cache-warmer";
    platforms = lib.platforms.darwin;
  };
}
