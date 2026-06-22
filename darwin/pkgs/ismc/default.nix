{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:
buildGoModule rec {
  pname = "ismc";
  version = "0.13.5";

  src = fetchFromGitHub {
    owner = "dkorunic";
    repo = "iSMC";
    rev = "v${version}";
    hash = "sha256-bFUw3arW4RUq5ivhxSW5K/E7SFARhO3QgPxUKayMJ6I=";
  };

  vendorHash = "sha256-yzu9EO8GLs8LqVbNqIT5OB/qD7PN/2VTobd4zWJaytw=";

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
    license = lib.licenses.gpl3Only;
    mainProgram = "iSMC";
    platforms = lib.platforms.darwin;
    maintainers = [ ];
  };
}
