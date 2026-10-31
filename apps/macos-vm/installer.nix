{
  fetchurl,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "macos-vm-nix-installer";
  version = "2.35.3";

  src = fetchurl {
    url = "https://github.com/NixOS/nix-installer/releases/download/${finalAttrs.version}/nix-installer-aarch64-darwin";
    hash = "sha256-xJkVYqcafvLcUtl2BUXIVB20pGi7zJHcr9VxdWOL8X4=";
  };

  dontUnpack = true;
  dontBuild = true;
  # Keep the standalone upstream executable and its embedded Nix payload intact.
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    install -Dm555 "$src" "$out/share/fleet-macos-vm/nix-installer"
    runHook postInstall
  '';

  meta = {
    description = "Standalone Nix installer payload for Apple silicon macOS guests";
    homepage = "https://github.com/NixOS/nix-installer";
    changelog = "https://github.com/NixOS/nix-installer/releases/tag/${finalAttrs.version}";
    license = lib.licenses.lgpl21Plus;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    # This is transferred into a guest; the packaging host never executes it.
    platforms = lib.platforms.unix;
  };
})
