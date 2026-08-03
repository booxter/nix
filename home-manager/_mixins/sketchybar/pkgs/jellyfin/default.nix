{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "sketchybar-jellyfin";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-WOE+6bYAcerTiONLfSgz78Kjz/riiA8FGspdQSfdSGM=";

  subPackages = [ "cmd/sketchybar-jellyfin" ];

  preCheck = ''
    test -z "$(gofmt -l .)"
    go vet ./...
  '';
  checkFlags = [ "-cover" ];

  meta = {
    description = "Jellyfin activity plugin for SketchyBar";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sketchybar-jellyfin";
    platforms = lib.platforms.darwin;
  };
}
