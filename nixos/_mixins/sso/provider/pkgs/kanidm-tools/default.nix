{
  clippy,
  lib,
  makeWrapper,
  nix,
  openssh,
  providerInventory ? { },
  rustfmt,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "kanidm-tools";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
    ];
  };

  cargoHash = "sha256-wqe6mr0e2tLijyBULreIZ3CiP5+GiONYuzMWVbRB0J4=";

  RESET_OIDC_SSH = lib.getExe openssh;

  nativeCheckInputs = [
    clippy
    rustfmt
  ];
  nativeBuildInputs = [ makeWrapper ];

  preCheck = ''
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
  '';
  cargoTestFlags = [ "--all-targets" ];

  postFixup = ''
    wrapProgram "$out/bin/reset-oidc" \
      --prefix PATH : ${lib.makeBinPath [ nix ]} \
      --set RESET_OIDC_PROVIDERS_FILE ${builtins.toFile "sso-providers.json" (builtins.toJSON providerInventory)} \
      --set RESET_OIDC_PROVIDERS_QUERY_FILE ${../../providers-query.nix}
  '';

  meta = {
    description = "Administrative tools for a Kanidm SSO provider";
    license = lib.licenses.mit;
    mainProgram = "reset-oidc";
    platforms = lib.platforms.unix;
  };
}
