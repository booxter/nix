{
  buildNpmPackage,
  fetchFromGitHub,
  geckodriver,
  lib,
  makeWrapper,
  nodejs_24,
  versionCheckHook,
}:

buildNpmPackage rec {
  pname = "firefox-devtools-mcp";
  version = "0.11.0";

  src = fetchFromGitHub {
    owner = "mozilla";
    repo = "firefox-devtools-mcp";
    tag = "v${version}";
    hash = "sha256-ELxWz0N7IfRGeE6WlxwH68bqP2ZRmuPVV0z2W10gQGQ=";
  };

  nodejs = nodejs_24;
  npmDepsHash = "sha256-DWVdaLsJINQ0EloydHX2KjvY1AfpyEeO5saYiF1Pdvw=";

  nativeBuildInputs = [
    makeWrapper
  ];

  npmFlags = [
    "--ignore-scripts"
  ];

  postInstall = ''
    wrapProgram "$out/bin/firefox-mcp" \
      --prefix PATH : ${lib.makeBinPath [ geckodriver ]}
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    versionCheckHook
  ];

  meta = {
    description = "Model Context Protocol server for Firefox DevTools automation";
    homepage = "https://github.com/mozilla/firefox-devtools-mcp";
    changelog = "https://github.com/mozilla/firefox-devtools-mcp/releases/tag/v${version}";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "firefox-mcp";
    platforms = lib.platforms.unix;
  };
}
