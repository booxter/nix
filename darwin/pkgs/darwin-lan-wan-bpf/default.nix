{
  lib,
  libpcap,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "darwin-lan-wan-bpf";
  version = "0.1.0";

  src = ./.;

  buildInputs = [ libpcap ];

  buildPhase = ''
    runHook preBuild

    $CC -Wall -Wextra -O2 -o darwin-lan-wan-bpf main.c -lpcap

    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    $CC -Wall -Wextra -Wno-unused-function -O2 \
      -o darwin-lan-wan-bpf-tests test.c -lpcap
    ./darwin-lan-wan-bpf-tests

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    install -m755 darwin-lan-wan-bpf "$out/bin/darwin-lan-wan-bpf"

    runHook postInstall
  '';

  meta = {
    description = "Darwin libpcap probe for LAN/WAN interface byte accounting";
    license = lib.licenses.mit;
    mainProgram = "darwin-lan-wan-bpf";
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.darwin;
  };
}
