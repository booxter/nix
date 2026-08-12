{ lib }:
let
  importanceOrder = [
    "critical"
    "important"
    "normal"
    "best-effort"
  ];
  importanceRanks = {
    critical = 4;
    important = 3;
    normal = 2;
    best-effort = 1;
  };
  byId = builtins.sort (left: right: left.id < right.id);
  roundRobinByOwner =
    candidates:
    let
      grouped = builtins.groupBy (candidate: candidate.owner) (byId candidates);
      takeRounds =
        groups:
        let
          active = lib.filterAttrs (_: entries: entries != [ ]) groups;
          owners = builtins.sort builtins.lessThan (builtins.attrNames active);
        in
        if owners == [ ] then
          [ ]
        else
          map (owner: builtins.head active.${owner}) owners
          ++ takeRounds (lib.mapAttrs (_: entries: builtins.tail entries) active);
    in
    takeRounds grouped;
  orderCandidates =
    spreadByOwner: candidates:
    builtins.concatMap (
      importance:
      let
        tier = builtins.filter (
          candidate: candidate.value.observability.importance == importance
        ) candidates;
      in
      if spreadByOwner then roundRobinByOwner tier else byId tier
    ) importanceOrder;
in
{
  capacity,
  candidates,
  minimumImportance ? "best-effort",
  spreadByOwner ? true,
}:
let
  enabled = builtins.filter (
    candidate:
    candidate.value.observability.externalProbe.enable
    && candidate.value.observability.externalProbe.requirement != "disabled"
    && (
      candidate.value.observability.externalProbe.requirement == "required"
      ||
        importanceRanks.${candidate.value.observability.importance} >= importanceRanks.${minimumImportance}
    )
  ) candidates;
  required = orderCandidates spreadByOwner (
    builtins.filter (
      candidate: candidate.value.observability.externalProbe.requirement == "required"
    ) enabled
  );
  optional = orderCandidates spreadByOwner (
    builtins.filter (
      candidate: candidate.value.observability.externalProbe.requirement == "eligible"
    ) enabled
  );
  remainingCapacity = lib.max 0 (capacity - builtins.length required);
  selected = required ++ lib.take remainingCapacity optional;
  selectedIds = map (candidate: candidate.id) selected;
in
{
  inherit
    enabled
    optional
    required
    selected
    selectedIds
    ;
  omitted = builtins.filter (candidate: !builtins.elem candidate.id selectedIds) enabled;
  requiredOverflow = builtins.length required > capacity;
}
