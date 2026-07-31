{
  buildGoModule,
  fetchFromGitHub,
  lib,
  versionCheckHook,
}:
buildGoModule rec {
  pname = "ismc";
  version = "0.17.1";

  src = fetchFromGitHub {
    owner = "dkorunic";
    repo = "iSMC";
    rev = "v${version}";
    hash = "sha256-fJTpWps6bAVHYzwRKSJ3WPYvOnUDhlhvEi3EpC2DgXg=";
  };

  vendorHash = "sha256-ubvFyu5cgsSN0yDAtGifxCpIiRI3CZM1QJUrR8bHYHA=";

  env.CGO_ENABLED = 1;

  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
    "-X"
    "github.com/dkorunic/iSMC/internal/cmd.GitTag=v${version}"
    "-X"
    "github.com/dkorunic/iSMC/internal/cmd.GitCommit=${src.rev}"
    "-X"
    "github.com/dkorunic/iSMC/internal/cmd.GitDirty="
    "-X"
    "github.com/dkorunic/iSMC/internal/cmd.BuildTime=unknown"
  ];

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgram = "${builtins.placeholder "out"}/bin/iSMC";
  versionCheckProgramArg = "version";

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
