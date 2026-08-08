{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "grafana-dashboards";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-2ZSlZYm0/mR9pfFU+YY0PeLB1HxR6/57/xK9JF74R5E=";

  subPackages = [ "cmd/grafana-dashboards" ];

  preCheck = ''
    test -z "$(gofmt -l .)"
    go vet ./...
  '';
  checkPhase = ''
    runHook preCheck
    go test ./... -cover
    runHook postCheck
  '';

  meta = {
    description = "Generate inventory-driven Grafana dashboards";
    license = lib.licenses.mit;
    mainProgram = "grafana-dashboards";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
