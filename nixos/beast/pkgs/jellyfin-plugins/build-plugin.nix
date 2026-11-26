{
  lib,
  buildDotnetModule,
  dotnetCorePackages,
  stdenv,
}:
{
  pluginId,
  pluginName,
  pluginFiles,
  targetAbi,
  localRevision ? 1,
  ...
}@args:
let
  packageArgs = removeAttrs args [
    "pluginId"
    "pluginName"
    "pluginFiles"
    "targetAbi"
    "localRevision"
  ];
  sourceParts = lib.splitString "." args.version;
  upstreamParts = lib.take 4 (sourceParts ++ lib.replicate 3 "0");
  versionPosition = builtins.unsafeGetAttrPos "version" args;
  # Jellyfin only updates to a greater assembly version. Reserve two digits
  # within the final component for local rebuilds of each upstream release.
  revision = lib.toInt (builtins.elemAt upstreamParts 3) * 100 + localRevision;
  version = lib.concatStringsSep "." ((lib.take 3 upstreamParts) ++ [ (toString revision) ]);
in
assert builtins.length sourceParts >= 1 && builtins.length sourceParts <= 4;
assert localRevision > 0 && localRevision < 100 && revision <= 65535;
buildDotnetModule (
  {
    dotnet-sdk = dotnetCorePackages.sdk_9_0;
    dotnet-runtime = dotnetCorePackages.aspnetcore_9_0;
    executables = [ ];
    installPath = builtins.placeholder "out";
    runtimeId = if stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64";
  }
  // packageArgs
  // {
    inherit version;
    dotnetFlags = (args.dotnetFlags or [ ]) ++ [
      "-p:Version=${version}"
      "-p:AssemblyVersion=${version}"
      "-p:FileVersion=${version}"
    ];
    passthru = (args.passthru or { }) // {
      inherit
        pluginId
        pluginName
        pluginFiles
        targetAbi
        ;
      upstreamVersion = args.version;
    };
    meta = (args.meta or { }) // {
      platforms = lib.platforms.linux;
      position = "${versionPosition.file}:${toString versionPosition.line}";
    };
  }
)
