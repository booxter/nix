{
  pkgs,
  jellyfin,
  localRevision,
}:
let
  buildPlugin = pkgs.callPackage ../../../nixos/beast/pkgs/jellyfin-plugins/build-plugin.nix { };
in
buildPlugin {
  pname = "jellyfin-plugin-catalogue-fixture";
  version = "1.0.0";
  inherit localRevision;
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./Fixture.csproj
      ./Plugin.cs
    ];
  };
  pluginId = "6d033048-d833-4df8-bfb5-d7555d612737";
  pluginName = "Catalogue Fixture";
  pluginFiles = [ "Fixture.dll" ];
  targetAbi = "12.0.0.0";
  projectFile = "Fixture.csproj";
  nugetDeps = [ ];
  dotnet-sdk = pkgs.dotnetCorePackages.sdk_10_0;
  dotnet-runtime = pkgs.dotnetCorePackages.aspnetcore_10_0;
  dotnetFlags = [ "-p:JellyfinLib=${jellyfin}/lib/jellyfin" ];
  meta.description = "Plugin catalogue integration test fixture";
}
