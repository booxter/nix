{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "backup-server-tools";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  subPackages = [
    "cmd/restic-repo-acl"
  ];

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
    description = "Native maintenance tools for a Restic backup server";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
