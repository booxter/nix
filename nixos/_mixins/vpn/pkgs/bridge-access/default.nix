{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "vpn-namespace-bridge-access";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-n/S9knZuLgr4Lgv/+o5w1/Rd8E8Qfc5uymfBl7rfYJ0=";

  subPackages = [ "cmd/wg-bridge-access" ];

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
    description = "Manage host access to services in VPN namespaces";
    license = lib.licenses.mit;
    mainProgram = "wg-bridge-access";
    platforms = lib.platforms.linux;
  };
}
