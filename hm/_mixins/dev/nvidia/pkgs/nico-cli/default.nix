{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

buildGoModule rec {
  pname = "nico-cli";
  version = "2.4.0-rc.8";

  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "infra-controller";
    rev = "v${version}";
    hash = "sha256-ROh8yQLRtuS+BNg8bboeDHSBwJRleC+oo3lt1RlthGg=";
  };

  modRoot = "./rest-api";
  subPackages = [ "cli/cmd/cli" ];
  vendorHash = "sha256-tge70gKC9tai253zmSptKSOwYBG1cHG/mtXhfKN8XTY=";

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
