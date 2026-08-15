{
  lib,
  attic-client,
  clippy,
  nix,
  pushToAttic ? true,
  rustfmt,
  rustPlatform,
  warmTargets,
}:
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
  FLEET_CACHE_WARMER_TARGETS_JSON = builtins.toJSON warmTargets;

  nativeCheckInputs = [
    clippy
    rustfmt
  ];

  preCheck = ''
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
  '';
  cargoTestFlags = [ "--all-targets" ];

  passthru.ciWarmTargets = warmTargets;

  meta = {
    description = "Build CI-validated fleet outputs and optionally push them to Attic";
    license = lib.licenses.mit;
    mainProgram = "fleet-cache-warmer";
    platforms = lib.platforms.darwin;
  };
}
