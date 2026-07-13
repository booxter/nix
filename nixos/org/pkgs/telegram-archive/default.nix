{
  fetchFromGitHub,
  lib,
  makeWrapper,
  python314,
  stdenvNoCC,
}:
let
  runtimePackages =
    ps: with ps; [
      aiosqlite
      alembic
      apscheduler
      asyncpg
      beautifulsoup4
      cryptg
      cryptography
      fastapi
      greenlet
      httpx
      jinja2
      pillow
      psycopg2
      py-vapid
      python-dotenv
      python-socks
      pywebpush
      sqlalchemy
      # Telegram Archive requires Python 3.14. Telethon's upstream metadata has
      # not caught up yet, but the version in nixpkgs works on 3.14.
      (telethon.overridePythonAttrs (_: {
        disabled = false;
        # One helper test assumes Python's pre-3.14 implicit event loop. The
        # async client paths used by Telegram Archive do not rely on it.
        doCheck = false;
      }))
      uvicorn
      websockets
    ];
  pythonEnv = python314.withPackages runtimePackages;
in
stdenvNoCC.mkDerivation rec {
  pname = "telegram-archive";
  version = "7.20.0";

  src = fetchFromGitHub {
    owner = "GeiserX";
    repo = "Telegram-Archive";
    tag = "v${version}";
    hash = "sha256-HfR5XytzgQ1RB2YcypA/9r7uzarijwEQwcUpzODCJDM=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/telegram-archive"
    cp -R alembic src "$out/share/telegram-archive/"
    cp alembic.ini LICENSE README.md pyproject.toml "$out/share/telegram-archive/"

    makeWrapper ${pythonEnv}/bin/python "$out/bin/telegram-archive" \
      --chdir "$out/share/telegram-archive" \
      --add-flags "-m src"
    makeWrapper ${pythonEnv}/bin/python "$out/bin/telegram-archive-viewer" \
      --chdir "$out/share/telegram-archive" \
      --add-flags "-m uvicorn src.web.main:app"

    runHook postInstall
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    ${pythonEnv}/bin/python -m compileall -q src
    PYTHONPATH="$PWD" ${pythonEnv}/bin/python -c \
      'from src.config import Config; from src.db import create_adapter; from src.telegram_backup import TelegramBackup'

    runHook postCheck
  '';

  passthru = {
    inherit pythonEnv;
    updateScript = [ ./update.sh ];
  };

  meta = {
    description = "Incremental Telegram history and media archiver";
    homepage = "https://github.com/GeiserX/Telegram-Archive";
    changelog = "https://github.com/GeiserX/Telegram-Archive/releases/tag/v${version}";
    license = lib.licenses.gpl3Plus;
    mainProgram = "telegram-archive";
    platforms = lib.platforms.linux;
  };
}
