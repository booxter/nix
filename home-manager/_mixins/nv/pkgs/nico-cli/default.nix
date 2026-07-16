{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

buildGoModule rec {
  pname = "nico-cli";
  version = "2.0.0-rc.7";

  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "infra-controller";
    rev = "v${version}";
    hash = "sha256-ak5xl1dJmFmHw/Ds9/LzmVZ5/XZcBEur0W8z+i+2pTo=";
  };

  modRoot = "./rest-api";
  subPackages = [ "cli/cmd/cli" ];
  vendorHash = "sha256-IQIXhZyaMCjhUSyMyuXeWMlJhgze5I1v5+pu3Wc8eeM=";

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
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "nicocli";
    platforms = lib.platforms.unix;
  };
}
