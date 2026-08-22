{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "btrfs-maintenance";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  subPackages = [ "cmd/btrfs-maintenance" ];

  preCheck = ''
    unformatted="$(gofmt -l cmd internal)"
    if test -n "$unformatted"; then
      gofmt -d cmd internal >&2
      exit 1
    fi
    go vet ./...
  '';
  checkPhase = ''
    runHook preCheck
    go test ./... -cover
    runHook postCheck
  '';

  meta = {
    description = "Maintain Btrfs snapshots and interrupted scrubs";
    license = lib.licenses.mit;
    mainProgram = "btrfs-maintenance";
    platforms = lib.platforms.linux;
  };
}
