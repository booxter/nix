{
  buildGoModule,
  lib,
  makeWrapper,
  openssh,
}:
let
  application = buildGoModule {
    pname = "seerr-tools";
    version = "0.1.0";

    src = ./.;

    vendorHash = "sha256-aXJxOLBG/fthkGLhgxEGeyDBG0sLSeF5UTRG/TqUUbE=";

    subPackages = [ "cmd/seerr-request-storage" ];

    nativeBuildInputs = [ makeWrapper ];

    postInstall = ''
      wrapProgram $out/bin/seerr-request-storage \
        --prefix PATH : ${lib.makeBinPath [ openssh ]}
    '';

    preCheck = ''
      test -z "$(gofmt -l .)"
      go vet ./...
    '';
    checkPhase = ''
      runHook preCheck
      go test ./... -cover
      runHook postCheck
    '';

    __darwinAllowLocalNetworking = true;

    meta = {
      description = "Seerr storage reporting and maintenance tools";
      license = lib.licenses.mit;
      maintainers = with lib.maintainers; [ booxter ];
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  };
  withMainProgram =
    mainProgram:
    application
    // {
      meta = application.meta // {
        inherit mainProgram;
      };
    };
in
{
  package = application;
  requestStorage = withMainProgram "seerr-request-storage";
}
