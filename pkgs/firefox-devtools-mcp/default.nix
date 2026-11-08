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
  version = "0.10.7";

  src = fetchFromGitHub {
    owner = "mozilla";
    repo = "firefox-devtools-mcp";
    tag = "v${version}";
    hash = "sha256-B/BL2ou9l5wgAzvc0PiuMphYp/mRmw3c4bRsynugAKs=";
  };

  nodejs = nodejs_24;
  npmDepsHash = "sha256-tSufdG4ov8GCrB7bZmLpw78fJlc5qo7EKy4FikVy938=";

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
