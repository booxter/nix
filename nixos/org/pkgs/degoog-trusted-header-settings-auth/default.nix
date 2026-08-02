{
  nodejs,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "degoog-trusted-header-settings-auth";
  version = "1.0.0";

  src = ./.;

  dontBuild = true;

  nativeCheckInputs = [ nodejs ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    node --test index.test.mjs

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp index.mjs "$out/"

    runHook postInstall
  '';
}
