{
  glab,
  lib,
  makeBinaryWrapper,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "glab-mr-create";
  inherit (glab) version;

  dontUnpack = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    install -d $out/bin
    makeWrapper ${lib.getExe glab} $out/bin/glab-mr-create \
      --add-flags "mr create --fill --remove-source-branch --push"
  '';

  meta = glab.meta // {
    description = "Create a filled GitLab merge request and push its source branch";
    mainProgram = "glab-mr-create";
  };
}
