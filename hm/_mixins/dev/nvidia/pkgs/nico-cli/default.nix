{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

buildGoModule rec {
  pname = "nico-cli";
  version = "2.3.0-rc.4";

  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "infra-controller";
    rev = "v${version}";
    hash = "sha256-b43KiTu1FA/6Hyemy1bSWLhodEeHxBR3r7w1Hvxw3b8=";
  };

  modRoot = "./rest-api";
  subPackages = [ "cli/cmd/cli" ];
  vendorHash = "sha256-LZbKLeNCBlu95X+lbHCgKrEQv38wBosEIm4eKzS4xY8=";

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
