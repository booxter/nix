{
  buildGoModule,
  fetchFromGitHub,
  lib,
  writableTmpDirAsHomeHook,
}:

buildGoModule rec {
  pname = "gamarr";
  version = "1.2.0";

  src = fetchFromGitHub {
    owner = "JeremiahM37";
    repo = "gamarr";
    tag = "v${version}";
    hash = "sha256-Ya5L8EQYT/OdTCwNHpKwKXU+RvCIW7TpcVhRc+vMNPk=";
  };

  vendorHash = "sha256-8X4Ldol3nZFNrKE+qPCjx8WPJ5wbQh83ZcVI33C7Fbs=";

  subPackages = [ "cmd/gamarr" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
  ];

  postPatch = ''
    substituteInPlace internal/config/config.go \
      --replace-fail 'if v := os.Getenv(key); v != "" {' 'if v, ok := os.LookupEnv(key); ok {'
    substituteInPlace internal/download/manager.go \
      --replace-fail 'func (m *Manager) RecoverOrphanedTorrents() {' 'func (m *Manager) RecoverOrphanedTorrents() {
        if !m.cfg.HasQBittorrent() {
          slog.Info("orphan recovery disabled; qBittorrent is not configured")
          return
        }
      '
  '';

  nativeBuildInputs = [ writableTmpDirAsHomeHook ];

  meta = {
    description = "Self-hosted game and ROM search, download, and library manager";
    homepage = "https://github.com/JeremiahM37/gamarr";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "gamarr";
    platforms = lib.platforms.linux;
  };
}
