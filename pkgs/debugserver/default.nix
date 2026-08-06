{
  curl,
  fetchurl,
  gnused,
  jq,
  lib,
  nix,
  stdenvNoCC,
  unzip,
  writeShellApplication,
}:
let
  # Vendored from the package proposed in NixOS/nixpkgs#374846. The original
  # expression is retained in the source branch at:
  # https://github.com/reckenrode/nixpkgs/blob/ceda7418a329564565158a005b989729c03f377c/pkgs/by-name/de/debugserver/package.nix
  platforms = {
    aarch64-darwin = {
      arch = "arm64";
      hash = "sha256-yDa4HG8tpGe1kgo3anv8hJ3EtNgbGXed7fHGhctKoaA=";
    };
    x86_64-darwin = {
      arch = "x64";
      hash = "sha256-gnCjQpKb3A3rbX05McCNW6YBgmX4QN0FCMQkf7jTLo0=";
    };
  };
  platform =
    platforms.${stdenvNoCC.hostPlatform.system} or {
      arch = "unsupported";
      hash = lib.fakeHash;
    };
  inherit (platform) arch hash;
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "debugserver";
  version = "1.12.2";

  src = fetchurl {
    url = "https://github.com/vadimcn/codelldb/releases/download/v${finalAttrs.version}/codelldb-darwin-${arch}.vsix";
    inherit hash;
  };

  nativeBuildInputs = [ unzip ];

  buildCommand = ''
    unzip "$src"
    mkdir -p "$out/bin"
    cp extension/lldb/bin/debugserver "$out/bin"
  '';

  dontFixup = true;

  passthru.updateScript = writeShellApplication {
    name = "update-debugserver";
    runtimeInputs = [
      curl
      gnused
      jq
      nix
    ];
    text = builtins.readFile ./update.sh;
  };

  meta = {
    description = "debugserver binary for use with LLDB";
    homepage = "https://github.com/vadimcn/codelldb";
    changelog = "https://github.com/vadimcn/codelldb/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    mainProgram = "debugserver";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
