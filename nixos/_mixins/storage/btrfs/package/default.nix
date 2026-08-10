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
    test -z "$(gofmt -l cmd internal)"
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
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "btrfs-maintenance";
    platforms = lib.platforms.linux;
  };
}
