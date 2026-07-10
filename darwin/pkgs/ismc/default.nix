{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:
buildGoModule rec {
  pname = "ismc";
  version = "0.16.7";

  src = fetchFromGitHub {
    owner = "dkorunic";
    repo = "iSMC";
    rev = "v${version}";
    hash = "sha256-Z3F45EABhoCLGIK8fS4ix/LDXBFmiQQishNzUM4xuRQ=";
  };

  vendorHash = "sha256-OlYOlfkOY0dKvJbnX0Ogld9UOPEhomUACB2WxTfMMhQ=";

  env.CGO_ENABLED = 1;

  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
    "-X"
    "github.com/dkorunic/iSMC/cmd.GitTag=v${version}"
    "-X"
    "github.com/dkorunic/iSMC/cmd.GitCommit=${src.rev}"
    "-X"
    "github.com/dkorunic/iSMC/cmd.GitDirty="
  ];

  meta = {
    description = "Apple SMC CLI for temperatures, fans, battery, power, voltage and current";
    homepage = "https://github.com/dkorunic/iSMC";
    changelog = "https://github.com/dkorunic/iSMC/releases/tag/v${version}";
    license = lib.licenses.gpl3Only;
    mainProgram = "iSMC";
    platforms = lib.platforms.darwin;
    maintainers = [ ];
  };
}
