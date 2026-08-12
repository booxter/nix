{ pkgs, ... }:
let
  inherit (pkgs) lib;
  plan = import ../../nixos/_lib/external-probe-planner.nix { inherit lib; };
  candidate =
    {
      id,
      owner,
      importance ? "normal",
      requirement ? "eligible",
      enable ? true,
    }:
    {
      inherit id owner;
      value.observability = {
        inherit importance;
        externalProbe = { inherit enable requirement; };
      };
    };
  candidates = [
    (candidate {
      id = "required-service";
      owner = "node-a";
      importance = "critical";
      requirement = "required";
    })
    (candidate {
      id = "a-service";
      owner = "node-a";
      importance = "important";
    })
    (candidate {
      id = "b-service";
      owner = "node-a";
      importance = "important";
    })
    (candidate {
      id = "c-service";
      owner = "node-b";
      importance = "important";
    })
    (candidate {
      id = "best-effort-service";
      owner = "node-c";
      importance = "best-effort";
    })
    (candidate {
      id = "disabled-service";
      owner = "node-c";
      requirement = "disabled";
    })
  ];
  selected = plan {
    capacity = 4;
    inherit candidates;
  };
  overflow = plan {
    capacity = 0;
    inherit candidates;
  };
in
assert
  selected.selectedIds == [
    "required-service"
    "a-service"
    "c-service"
    "b-service"
  ];
assert map (entry: entry.id) selected.omitted == [ "best-effort-service" ];
assert overflow.requiredOverflow;
pkgs.runCommand "external-probe-planner-test" { } ''
  touch "$out"
''
