{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  jsoncpp,
  systemd,
  gtest,
  nix-update-script,
}:
let
  kernelTestFilter = lib.concatStringsSep ":" [
    "CgroupContextTest.MonitorRootHost"
    "FsTest.GetxattrAtDistinguishesPresentMissingAndError"
    "XattrValueMatcherScopeTest.*"
    "XattrGlobTest.InvalidReinitDoesNotRetainPolicy"
    "XattrGlobTest.MatchesWholeXattrValueAndDenyWins"
    "XattrGlobTest.RejectsInvalidXattrValue"
    "XattrGlobTest.RulesetSelectorAllowsAnyMatchAndDenyWins"
  ];
in
stdenv.mkDerivation {
  pname = "oomd";
  version = "0.5.0-unstable-2026-11-13";

  # v0.5.0 predates reclaim_unmapped_anon and its EAGAIN handling. Track main
  # until a release includes these; then return to tagged release updates.
  src = fetchFromGitHub {
    owner = "facebookincubator";
    repo = "oomd";
    rev = "c0e7efcf04effaf50da84044992a38ecaecd7454";
    hash = "sha256-/Lj29yae0MUCWYPXwJg6YX/lX9XKmXyYWcqV9LmuACE=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];
  buildInputs = [
    jsoncpp
    systemd
  ];
  nativeCheckInputs = [ gtest ];
  doCheck = true;
  outputs = [
    "out"
    "tests"
  ];

  # Nix's sandbox has no cgroup mount and its build filesystem can reject
  # xattrs. Run these kernel/filesystem-dependent cases in oomd-package.nix.
  preCheck = ''
    export GTEST_FILTER='-${kernelTestFilter}'
  '';

  # The upstream example enables process killing. Consumers supply their own
  # policy and unit; installing the binary must not provide a default policy.
  postInstall = ''
    rm -rf "$out/etc" "$out/lib/systemd"
    mkdir -p "$tests/bin" "$tests/share/oomd"
    cp oomd_*_tests "$tests/bin/"
    cp -r ../src/oomd/fixtures "$tests/share/oomd/"
  '';

  passthru = {
    inherit kernelTestFilter;
    updateScript = nix-update-script {
      extraArgs = [ "--version=branch=main" ];
    };
  };

  meta = {
    description = "Userspace memory management with proactive Senpai reclaim";
    homepage = "https://github.com/facebookincubator/oomd";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "oomd";
  };
}
