"use strict";

function nixBuildCmd(attr) {
  return `nix build .#${attr} -L --show-trace`;
}

function hostTargetForAttr(attr) {
  const match = attr.match(/^(nixos|darwin)Configurations\.([^.]+)\./);
  return match ? { platform: match[1], host: match[2] } : null;
}

function diffMachineForAttr(attr) {
  const target = hostTargetForAttr(attr);
  if (!target) {
    return null;
  }
  const expected =
    target.platform === "nixos"
      ? `nixosConfigurations.${target.host}.config.system.build.toplevel`
      : `darwinConfigurations.${target.host}.system`;
  return attr === expected ? target.host : null;
}

function toBuildMatrixEntries(targets) {
  const seen = new Set();

  return targets.map((target, index) => {
    const machine = diffMachineForAttr(target.attr);
    const shouldDiff = machine && !seen.has(machine);

    if (shouldDiff) {
      seen.add(machine);
    }

    return {
      name: target.name,
      cmd: nixBuildCmd(target.attr),
      diff_machine: shouldDiff ? machine : "",
      diff_order: shouldDiff ? String(index).padStart(3, "0") : "",
      os: target.runner,
    };
  });
}

function appendMapping(mapping, prefix, field, name) {
  if (!prefix) {
    return;
  }

  if (!mapping.has(prefix)) {
    mapping.set(prefix, new Set());
  }
  mapping.get(prefix).add(name);
}

function buildHostPathMap(targets, field) {
  const mapping = new Map();

  for (const target of targets) {
    const hostTarget = hostTargetForAttr(target.attr);
    if (hostTarget) {
      appendMapping(
        mapping,
        `${hostTarget.platform}/${hostTarget.host}/`,
        field,
        target.name,
      );
    }
  }

  return Array.from(mapping.entries()).map(([prefix, names]) => ({
    prefix,
    [field]: Array.from(names),
  }));
}

module.exports = {
  buildHostPathMap,
  nixBuildCmd,
  toBuildMatrixEntries,
};
