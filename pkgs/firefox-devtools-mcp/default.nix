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
  version = "0.9.7";

  src = fetchFromGitHub {
    owner = "mozilla";
    repo = "firefox-devtools-mcp";
    tag = "v${version}";
    hash = "sha256-ZaRh98iKbTEPOYdyxnK8o1mU1h6tIwRx1mZW0ozP/KY=";
  };

  nodejs = nodejs_24;
  npmDepsHash = "sha256-JnAivSiThEm+EPm6gY08zQfD/aaF2sLfz6YSfsle9uE=";

  postPatch = ''
    substituteInPlace src/config/constants.ts \
      --replace-fail "SERVER_VERSION = '0.7.1'" "SERVER_VERSION = '${version}'"
  '';

  nativeBuildInputs = [
    makeWrapper
  ];

  npmFlags = [
    "--ignore-scripts"
  ];

  postInstall = ''
    wrapProgram "$out/bin/firefox-devtools-mcp" \
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
    mainProgram = "firefox-devtools-mcp";
    platforms = lib.platforms.unix;
  };
}
