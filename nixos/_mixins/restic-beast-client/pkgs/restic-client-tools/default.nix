{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "restic-client-tools";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  subPackages = [ "cmd/reap-restic-ssh" ];

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
    description = "Linux lifecycle helpers for restic backup clients";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "reap-restic-ssh";
    platforms = lib.platforms.linux;
  };
}
