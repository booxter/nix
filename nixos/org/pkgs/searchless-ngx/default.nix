{
  cacert,
  fetchFromGitHub,
  lib,
  makeWrapper,
  python313,
  stdenvNoCC,
  writableTmpDirAsHomeHook,
}:
let
  runtimePackages =
    ps: with ps; [
      chromadb
      fastapi
      google-genai
      httpx
      loguru
      mcp
      pydantic-settings
      tenacity
      uvicorn
    ];
  pythonEnv = python313.withPackages runtimePackages;
  checkPythonEnv = python313.withPackages (
    ps:
    runtimePackages ps
    ++ (with ps; [
      pytest
      pytest-asyncio
      pytest-env
      respx
    ])
  );
in
stdenvNoCC.mkDerivation rec {
  pname = "searchless-ngx";
  version = "0.5.0";

  src = fetchFromGitHub {
    owner = "hensing";
    repo = "searchless-ngx";
    rev = "v${version}";
    hash = "sha256-W5cllQskPgu+uyI4af+9IfWVv15K08CCSQDiZy+0Z44=";
  };

  patches = [
    ./settings-provider-configuration.patch
    ./ollama-embedding-provider.patch
    ./litellm-fuzzy-matching.patch
    ./loopback-mcp-hosts.patch
    ./hermetic-test-embeddings.patch
  ];

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ writableTmpDirAsHomeHook ];

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    export PYTHONPATH="$PWD"
    export PAPERLESS_URL="http://mock"
    export PAPERLESS_TOKEN="mock"
    export GEMINI_API_KEY="mock"
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"

    ${checkPythonEnv}/bin/pytest tests

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/searchless-ngx"
    cp -R api core semantic server "$out/share/searchless-ngx/"
    cp LICENSE README.md pyproject.toml "$out/share/searchless-ngx/"

    makeWrapper ${pythonEnv}/bin/python "$out/bin/searchless-ngx" \
      --chdir "$out/share/searchless-ngx" \
      --add-flags "-m uvicorn server.app:app"

    runHook postInstall
  '';

  passthru = {
    inherit pythonEnv;
  };

  meta = {
    description = "Agentic RAG MCP server for Paperless-ngx";
    changelog = "https://github.com/hensing/searchless-ngx/releases/tag/v${version}";
    homepage = "https://github.com/hensing/searchless-ngx";
    license = lib.licenses.gpl3Plus;
    mainProgram = "searchless-ngx";
    platforms = lib.platforms.linux;
  };
}
