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
    "cmd/sketchybar-clock"
    "cmd/sketchybar-disk"
    "cmd/sketchybar-github-status"
    "cmd/sketchybar-ip-address"
    "cmd/sketchybar-jellyfin"
    "cmd/sketchybar-network"
    "cmd/sketchybar-stock"
    "cmd/sketchybar-volume"
  ];

  preCheck = ''
    unformatted="$(gofmt -l .)"
    if test -n "$unformatted"; then
      gofmt -d . >&2
      exit 1
    fi
    go vet ./...
  '';
  checkFlags = [ "-cover" ];

  __darwinAllowLocalNetworking = true;

  meta = {
    description = "Native personal plugins for SketchyBar";
    license = lib.licenses.mit;
    mainProgram = "sketchybar-jellyfin";
    platforms = lib.platforms.darwin;
  };
}
