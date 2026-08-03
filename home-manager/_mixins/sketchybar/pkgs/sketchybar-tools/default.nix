{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "sketchybar-tools";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-WOE+6bYAcerTiONLfSgz78Kjz/riiA8FGspdQSfdSGM=";

  subPackages = [
    "cmd/sketchybar-alertmanager"
    "cmd/sketchybar-github-status"
    "cmd/sketchybar-jellyfin"
  ];

  preCheck = ''
    test -z "$(gofmt -l .)"
    go vet ./...
  '';
  checkFlags = [ "-cover" ];

  meta = {
    description = "Native personal plugins for SketchyBar";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sketchybar-jellyfin";
    platforms = lib.platforms.darwin;
  };
}
