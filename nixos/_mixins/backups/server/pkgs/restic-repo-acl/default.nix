{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "restic-repo-acl";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  subPackages = [ "cmd/restic-repo-acl" ];

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
    description = "Maintain Restic repository access controls";
    license = lib.licenses.mit;
    mainProgram = "restic-repo-acl";
    platforms = lib.platforms.linux;
  };
}
