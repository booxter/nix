{
  buildGoModule,
  lib,
  makeWrapper,
  podman,
}:
buildGoModule {
  pname = "podman-machine-ensure";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  nativeBuildInputs = [ makeWrapper ];

  postFixup = ''
    wrapProgram "$out/bin/podman-machine-ensure" \
      --prefix PATH : ${lib.makeBinPath [ podman ]}
  '';

  preCheck = ''
    test -z "$(gofmt -l .)"
    go vet ./...
  '';
  checkFlags = [ "-cover" ];

  meta = {
    description = "Reconcile a declaratively configured Podman machine";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "podman-machine-ensure";
    platforms = lib.platforms.darwin;
  };
}
