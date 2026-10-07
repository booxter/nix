{
  lib,
  stdenv,
  codex,
  alsa-lib,
  bubblewrap,
  gst_all_1,
  libopus,
  ps,
  ripgrep,
  writeText,
}:
let
  voiceSupport =
    stdenv.hostPlatform.isDarwin || (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isGnu);
  voiceRuntimePackages = [
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
  ];
  voiceRuntimeRoots = map lib.getLib voiceRuntimePackages;
  voiceRuntime =
    let
      pluginDirectory = if stdenv.hostPlatform.isDarwin then "plugins" else "lib/gstreamer-1.0";
      pluginSuffix = stdenv.hostPlatform.extensions.sharedLibrary;
      plugin = package: name: {
        source = "${lib.getLib package}/lib/gstreamer-1.0/libgst${name}${pluginSuffix}";
        target = "${pluginDirectory}/libgst${name}${pluginSuffix}";
      };
      coreSuffix = if stdenv.hostPlatform.isDarwin then "0.dylib" else "so.0";
    in
    [
      {
        source = "${lib.getLib gst_all_1.gstreamer}/lib/libgstreamer-1.0.${coreSuffix}";
        target = "lib/libgstreamer-1.0.${coreSuffix}";
      }
      (plugin gst_all_1.gstreamer "coreelements")
      (plugin gst_all_1.gst-plugins-base "app")
      (plugin gst_all_1.gst-plugins-base "audioconvert")
      (plugin gst_all_1.gst-plugins-base "audioresample")
      (plugin gst_all_1.gst-plugins-base "opus")
      (plugin gst_all_1.gst-plugins-good "rtp")
      (plugin gst_all_1.gst-plugins-good "rtpmanager")
    ];
in
# Backport https://github.com/NixOS/nixpkgs/pull/566925 until it lands.
codex.overrideAttrs (
  final: old: {
    # rust-v0.160.0; both client and helper need the same release commit.
    buildCommit = "a956835d020762cb2b570053af06f643a11c0ecc";

    cargoDeps = old.cargoDeps.overrideAttrs (previous: {
      buildCommand = previous.buildCommand + ''
        chmod +w "$out/source-registry-0/opusic-sys-0.7.5/Cargo.toml"
        substituteInPlace "$out/source-registry-0/opusic-sys-0.7.5/Cargo.toml" \
          --replace-fail 'default = ["bundled"]' 'default = []'
      '';
    });

    cargoBuildFlags =
      old.cargoBuildFlags
      ++ lib.optionals voiceSupport [
        "--package"
        "codex-voice-host"
      ];

    patches = (old.patches or [ ]) ++ [
      ./nix-package-layout.patch
      ./nix-voice-runtime.patch
      # https://github.com/openai/codex/issues/47390
      ../../patches/codex-show-full-patches.patch
    ];

    buildInputs =
      old.buildInputs
      ++ lib.optionals voiceSupport (
        voiceRuntimePackages ++ [ libopus ] ++ lib.optionals stdenv.hostPlatform.isLinux [ alsa-lib ]
      );

    env =
      old.env
      // {
        CODEX_BUILD_COMMIT = final.buildCommit;
        STABLE_GIT_COMMIT = final.buildCommit;
        NIX_CODEX_PS = lib.getExe ps;
        NIX_CODEX_PACKAGE_LINK_ROOTS = lib.concatStringsSep ":" (
          [ (toString (lib.getBin ripgrep)) ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [ (toString (lib.getBin bubblewrap)) ]
          ++ lib.optionals voiceSupport (map toString voiceRuntimeRoots)
        );
      }
      // lib.optionalAttrs voiceSupport {
        NIX_CODEX_VOICE_RUNTIME_ROOTS = lib.concatStringsSep ":" (map toString voiceRuntimeRoots);
        OPUS_LIB_DIR = "${lib.getLib libopus}/lib";
      };

    postInstall = ''
      install -Dm444 ${
        writeText "codex-package.json" (
          builtins.toJSON {
            layoutVersion = 1;
            version = final.version;
            target = stdenv.hostPlatform.rust.rustcTarget;
            variant = "codex";
            entrypoint = "bin/codex";
            resourcesDir = "codex-resources";
          }
        )
      } $out/codex-package.json

      install -d $out/codex-path
      ln -s ${lib.getExe ripgrep} $out/codex-path/rg
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      install -d $out/codex-resources
      ln -s ${lib.getExe bubblewrap} $out/codex-resources/bwrap
    ''
    + lib.optionalString voiceSupport ''
      install -d $out/codex-resources/voice/bin
      mv $out/bin/codex-voice-host $out/codex-resources/voice/bin/
      ${lib.concatMapStringsSep "\n" (link: ''
        install -d $out/codex-resources/voice/${builtins.dirOf link.target}
        ln -s ${link.source} $out/codex-resources/voice/${link.target}
      '') voiceRuntime}
    ''
    + old.postInstall;

    # A wrapper changes the running executable's path, invalidating the
    # manifest entrypoint. Dependencies are discovered through the layout.
    postFixup = "";
  }
)
