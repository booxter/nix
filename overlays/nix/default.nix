{ nix, fetchpatch }:
nix.appendPatches [
  (fetchpatch {
    url = "https://github.com/booxter/nix-1/commit/42d741ac8140ab79d75f86e09c51f94497873441.patch";
    hash = "sha256-xOKyoupUL16v++Cy90sfWrK1g2R2kLglpJzTDza0vv0=";
  })
  (fetchpatch {
    url = "https://github.com/booxter/nix-1/commit/99f62a59fbc897e066962848e4036c59c4fc29c1.patch";
    hash = "sha256-v442hEwu1Ziq5nv3pg8Ex8RmFGNgp8L0hxRPDuIWq28=";
  })
  (fetchpatch {
    url = "https://github.com/booxter/nix-1/commit/6c23eaef1c437fcf77400ca021d7bd28716ce6d2.patch";
    hash = "sha256-UtVYaEz/yknD8Q/lWhLoHz/wLWJlZFxXr2quw3QqMkY=";
  })
  (fetchpatch {
    url = "https://github.com/booxter/nix-1/commit/0e40248b4eaf56a766f10ca4900b9b44187c3bfd.patch";
    hash = "sha256-ohV9C/mjZVueMDl460UVkAlXgnQ0AWhDS9RSUUeaK/o=";
  })
  (fetchpatch {
    url = "https://github.com/booxter/nix-1/commit/7cc467036383c9ee3abe989f5f515b1baee1147d.patch";
    hash = "sha256-Jfa3P644DWGwz6bPfYKKEUuH1dQEpVxeB6hJAbHKwEY=";
  })
  # Enable accounting controllers for per-build cgroups after the daemon
  # moves itself into its leaf cgroup.
  (fetchpatch {
    url = "https://github.com/NixOS/nix/commit/68d4049ceaf4d37837d3c2fdfe415f48737d1f64.patch";
    hash = "sha256-H2XyUQg8uYrhlCV7Sj7CE6Ow/uGGdLqUlK7azTtwE88=";
  })
  # Keep SIGCHLD from writing to a self-pipe closed during daemon shutdown.
  (fetchpatch {
    url = "https://github.com/NixOS/nix/commit/20e5b8e84cfa0718323f6d93eabd86a73ff86cc8.patch";
    hash = "sha256-K6ATPUbVP2JPsqsgshSuiBqYthZurx7imxjFyH2rcEk=";
  })
  # Keep remote build inputs rooted before checking or copying them.
  (fetchpatch {
    url = "https://github.com/NixOS/nix/commit/b104a21b59e1b4621196ca72fdab935308037432.patch";
    hash = "sha256-LXmF5B87gkvdr1GHJvyuNribazImMwfC+HyUgeCRc6U=";
  })
  (fetchpatch {
    url = "https://github.com/NixOS/nix/commit/d4c237e7216eea15fef6b8339889dbe7a0e1ad54.patch";
    hash = "sha256-Ef1Aj3Wrm8JttWfPzRpGjeC6t/uue5oX0rAiSCjlCZk=";
  })
  # Batch root registration to avoid a round trip for every input.
  (fetchpatch {
    url = "https://github.com/NixOS/nix/commit/011dcfe3f32552eccc5511cab52bf215f023e631.patch";
    hash = "sha256-wolYYtJ8t028aWKYR5ipk4mHopzcmPIEh9xp4SZrJQQ=";
    excludes = [ "src/libstore/remote-store.cc" ];
  })
  (fetchpatch {
    url = "https://github.com/NixOS/nix/commit/9b1503fdeb4fb075c93aaf114343c1daf9d5f4bd.patch";
    hash = "sha256-qdPnH8yYTeb2Dn8eF165Gib6QvfjAqqYSf17KzF7SE4=";
    excludes = [
      "src/libstore/remote-store.cc"
      "src/libstore/include/nix/store/worker-protocol.hh"
    ];
  })
  # Adapt the excluded files to 2.35.2, retaining the older-daemon fallback.
  ../../patches/nix-remote-temp-roots-2.35.patch
]
