{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

buildGoModule rec {
  pname = "nico-cli";
  version = "2.2.0-rc.1";

  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "infra-controller";
    rev = "v${version}";
    hash = "sha256-SjM7dEjmQ62kdaHGZK2flX3Pjuydk3KdQjFtawkIcko=";
  };

  modRoot = "./rest-api";
  subPackages = [ "cli/cmd/cli" ];
  vendorHash = "sha256-oAnT1oSZl/OBhtwWgjP6N+K88W1VzPhE+sOdYNyRqpg=";

  env.CGO_ENABLED = 0;

  ldflags = [
    "-s"
    "-w"
  ];

  postInstall = ''
    mv "$out/bin/cli" "$out/bin/nicocli"
  '';

  passthru.updateScript = [ ./update.sh ];

  meta = {
    description = "Command-line client for NVIDIA Infra Controller";
    homepage = "https://github.com/NVIDIA/infra-controller";
    changelog = "https://github.com/NVIDIA/infra-controller/tree/v${version}";
    license = lib.licenses.asl20;
    mainProgram = "nicocli";
    platforms = lib.platforms.unix;
  };
}
