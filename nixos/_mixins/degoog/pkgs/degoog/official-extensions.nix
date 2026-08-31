{
  applyPatches,
  degoogNodeModules,
  extensions ? [ ],
  extraExtensionSources ? { },
  fetchgit,
  lib,
  stdenvNoCC,
}:
let
  rev = "841af0aabeda3a5015d94d2030537c9da93dd0db";
  upstreamSrc = fetchgit {
    url = "https://github.com/degoog-org/official-extensions.git";
    inherit rev;
    hash = "sha256-9ICPNb+6ro9pzALx/OQkhQYXj+SqsKqVLp3bF92hRTI=";
  };
  src = applyPatches {
    name = "degoog-official-extensions-source";
    src = upstreamSrc;
    patches = [ ./romm-client-api-token.patch ];
  };
  validExtension =
    extension:
    builtins.match "^(autocomplete|engines|plugins|shortcuts|themes|transports)/[a-z0-9][a-z0-9._+-]*$" extension
    != null;
  invalidExtensions = builtins.filter (extension: !validExtension extension) extensions;
  invalidExtraExtensionSources = builtins.filter (extension: !validExtension extension) (
    builtins.attrNames extraExtensionSources
  );
  copyExtension =
    extension:
    let
      extensionType = builtins.head (lib.splitString "/" extension);
      extensionName = builtins.baseNameOf extension;
      canonicalName = "degoog-org-official-extensions-${extensionName}";
      isExtraExtension = builtins.hasAttr extension extraExtensionSources;
      installedName =
        if isExtraExtension then
          extensionName
        else if extensionType == "autocomplete" then
          "${canonicalName}-autocomplete"
        else if extensionType == "shortcuts" then
          "${canonicalName}-shortcut"
        else if extensionType == "themes" then
          "${canonicalName}-theme"
        else
          canonicalName;
      source = if isExtraExtension then extraExtensionSources.${extension} else "${src}/${extension}";
    in
    ''
      if [[ ! -d ${lib.escapeShellArg source} ]]; then
        echo "Degoog extension does not exist: ${extension}" >&2
        exit 1
      fi
      cp -R ${lib.escapeShellArg source} "$out/${extensionType}/${installedName}"
    '';
in
assert lib.assertMsg (
  invalidExtensions == [ ]
) "invalid Degoog extension paths: ${lib.concatStringsSep ", " invalidExtensions}";
assert lib.assertMsg (
  invalidExtraExtensionSources == [ ]
) "invalid extra Degoog extension paths: ${lib.concatStringsSep ", " invalidExtraExtensionSources}";
assert lib.assertMsg (lib.unique extensions == extensions) "duplicate Degoog extension paths";
stdenvNoCC.mkDerivation {
  pname = "degoog-official-extensions";
  # Upstream has no releases, so track its main branch as a pinned snapshot.
  # update-official-extensions.sh advances the revision through package-update CI.
  version = "0-unstable-2026-08-30";

  inherit src;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"/{autocomplete,engines,plugins,shortcuts,themes,transports}
    ${lib.concatMapStringsSep "\n" copyExtension extensions}
    ln -s ${degoogNodeModules}/node_modules "$out/node_modules"

    runHook postInstall
  '';

  passthru.updateScript = [ ./update-official-extensions.sh ];

  meta = {
    description = "Selected extensions from Degoog's official extension catalog";
    homepage = "https://github.com/degoog-org/official-extensions";
    changelog = "https://github.com/degoog-org/official-extensions/commit/${rev}";
    platforms = lib.platforms.all;
  };
}
