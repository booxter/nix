{
  fetchFromGitHub,
  fetchPnpmDeps,
  fetchPypi,
  lib,
  nodejs_22,
  pnpm,
  pnpmConfigHook,
  python313Packages,
}:
let
  aiosqlitepool = python313Packages.buildPythonPackage rec {
    pname = "aiosqlitepool";
    version = "1.0.0";
    pyproject = true;

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-OX95mT1/NKV0CTn7blL/KVY/rVxADvi3CZDmQzGVdAk=";
    };

    build-system = [ python313Packages.setuptools ];
    dependencies = [ python313Packages.aiosqlite ];

    pythonImportsCheck = [ "aiosqlitepool" ];

    meta = {
      description = "Asyncio connection pool for aiosqlite";
      homepage = "https://github.com/slaily/aiosqlitepool";
      license = lib.licenses.mit;
    };
  };
in
python313Packages.buildPythonApplication (finalAttrs: {
  pname = "houndarr";
  version = "1.12.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "av1155";
    repo = "houndarr";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Y+1KpdYI4cSbLJfIfXpPvOg6WEWzGVuNMqhiANPktpA=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname src version;
    fetcherVersion = 4;
    hash = "sha256-V/X8tWToeqLiPHOSBzGuEFCDPdTNxrNiA2Y+xDs0tYU=";
  };

  nativeBuildInputs = [
    nodejs_22
    pnpm
    pnpmConfigHook
  ];

  build-system = [ python313Packages.hatchling ];

  dependencies = with python313Packages; [
    aiosqlite
    aiosqlitepool
    async-lru
    bcrypt
    click
    cryptography
    fastapi
    httpx
    itsdangerous
    jinja2
    markupsafe
    pydantic
    python-multipart
    starlette
    uvicorn
  ];

  # Houndarr tracks newer compatible patch releases than the pinned nixpkgs
  # snapshot currently carries. Its upstream suite is run below against the
  # exact nixpkgs dependency set before the package is accepted.
  pythonRelaxDeps = [
    "aiosqlite"
    "click"
    "cryptography"
    "python-multipart"
    "starlette"
    "uvicorn"
  ];

  preBuild = ''
    pnpm build-css
  '';
  postInstall = ''
    # Houndarr resolves VERSION three parents above houndarr/__init__.py. The
    # container layout keeps it there naturally; reproduce that wheel runtime
    # layout under the Python prefix.
    install -Dm644 VERSION "$out/lib/python3.13/VERSION"
  '';

  nativeCheckInputs = with python313Packages; [
    pytest-asyncio
    pytestCheckHook
    respx
  ];
  pytestFlags = [
    "tests"
    "--ignore=tests/e2e_browser"
  ];
  preCheck = ''
    # Upstream's repository-invariant tests intentionally locate source files
    # relative to the imported houndarr module, so prefer the unpacked tree
    # over the already-installed wheel during pytestCheckPhase.
    export PYTHONPATH="$PWD/src:$PYTHONPATH"
  '';

  pythonImportsCheck = [ "houndarr" ];

  passthru.updateScript = [ ./update.sh ];

  meta = {
    description = "Polite missing, cutoff, and upgrade searches for Arr applications";
    homepage = "https://github.com/av1155/houndarr";
    changelog = "https://github.com/av1155/houndarr/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.agpl3Only;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "houndarr";
    platforms = lib.platforms.linux;
  };
})
