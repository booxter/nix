{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "backup-server-tools";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-EO32BX2lTYmaTNwuQd0LrdLPJYMPAwm9voLyZ0vSmHc=";

  subPackages = [
    "cmd/btrfs-maintenance"
    "cmd/restic-cloud-qos"
    "cmd/restic-repo-acl"
  ];

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
    description = "Native maintenance tools for the Beast backup server";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux;
  };
}
