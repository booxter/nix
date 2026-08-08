{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "grafana-dashboards";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-dfaRNSlE9+CDVYOrfOez5Idv3vyg6xWCSLhIYKdXq/I=";

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
