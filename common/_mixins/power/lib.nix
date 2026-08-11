{ lib }:
{
  build =
    hosts:
    let
      hostNames = builtins.attrNames hosts;
      parents = lib.mapAttrs (
        _: host: lib.unique (lib.concatLists (builtins.attrValues host.before))
      ) hosts;
      unknownTargets = lib.concatMap (
        name:
        map (target: {
          host = name;
          inherit target;
        }) (builtins.filter (target: !builtins.hasAttr target hosts) parents.${name})
      ) hostNames;
      depthFor =
        name:
        let
          visit =
            path: current:
            if builtins.elem current path then
              null
            else
              let
                knownParents = builtins.filter (parent: builtins.hasAttr parent hosts) parents.${current};
                parentDepths = map (visit (path ++ [ current ])) knownParents;
              in
              if builtins.any (depth: depth == null) parentDepths then
                null
              else if parentDepths == [ ] then
                0
              else
                1 + lib.foldl' lib.max 0 parentDepths;
        in
        visit [ ] name;
      depths = lib.genAttrs hostNames depthFor;
      cycleHosts = builtins.filter (name: depths.${name} == null) hostNames;
      upsServerFor =
        name:
        let
          ups = hosts.${name}.ups;
        in
        if ups.server.enable then name else ups.clientServer;
      upsServers = lib.genAttrs hostNames upsServerFor;
      upsHosts = lib.filterAttrs (_: server: server != null) upsServers;
      invalidUpsServers = builtins.filter (
        name:
        let
          serverName = upsServers.${name};
        in
        !builtins.hasAttr serverName hosts || !hosts.${serverName}.ups.server.enable
      ) (builtins.attrNames upsHosts);
      invalidPowerEdges = lib.concatMap (
        name:
        map
          (target: {
            host = name;
            inherit target;
          })
          (
            builtins.filter (
              target: builtins.hasAttr target hosts && upsServers.${target} != upsServers.${name}
            ) parents.${name}
          )
      ) (builtins.attrNames upsHosts);
      delays = lib.mapAttrs (
        name: serverName:
        let
          server = if builtins.hasAttr serverName hosts then hosts.${serverName}.ups.server else null;
          depth = depths.${name};
        in
        if server == null || !server.enable || depth == null then
          null
        else
          server.baseDelaySeconds - depth * server.separationSeconds
      ) upsHosts;
      invalidDelays = builtins.attrNames (lib.filterAttrs (_: delay: delay == null || delay <= 0) delays);
    in
    {
      inherit
        cycleHosts
        delays
        depths
        invalidDelays
        invalidPowerEdges
        invalidUpsServers
        parents
        unknownTargets
        upsServers
        ;
    };
}
