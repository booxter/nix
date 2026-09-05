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
  version = "0.10.2";

  src = fetchFromGitHub {
    owner = "mozilla";
    repo = "firefox-devtools-mcp";
    tag = "v${version}";
    hash = "sha256-WSlFNT0aG2DrP5hK1eDT47yb2L9NLztc81FBn1+jiT4=";
  };

  nodejs = nodejs_24;
  npmDepsHash = "sha256-s9SSFvbcNxxOVCIWbo1079Ysxqy2Z6+XyZoeMZXRB68=";

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
