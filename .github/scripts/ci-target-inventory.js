"use strict";

const inventory = require("../../ci-target-inventory.json");

function nixBuildCmd(attr) {
  return `nix build .#${attr} -L --show-trace`;
}

function diffMachineForAttr(attr) {
  const nixosMatch = attr.match(
    /^nixosConfigurations\.([^.]+)\.config\.system\.build\.toplevel$/,
  );
  if (nixosMatch) {
    return nixosMatch[1];
  }

  const darwinMatch = attr.match(/^darwinConfigurations\.([^.]+)\.system$/);
  if (darwinMatch) {
    return darwinMatch[1];
  }

  return null;
}

function toBuildMatrixEntries(targets) {
  const seen = new Set();

  return targets.map((target, index) => {
    // TODO: Make config diff targets explicit in ci-target-inventory.json
    // instead of deriving them from the build attr. The diff app currently
    // resolves short VM names like "org" back to runtime config names.
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

function buildMachinePathMap(targets, field) {
  const mapping = new Map();

  for (const target of targets) {
    const selection = target.selection || {};

    for (const prefix of selection.prefixes || []) {
      appendMapping(mapping, prefix, field, target.name);
    }

    for (const host of selection.hosts || []) {
      appendMapping(mapping, `secrets/${host}.yaml`, field, target.name);
      appendMapping(
        mapping,
        `secrets/_templates/${host}.yaml`,
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
  buildMachinePathMap,
  inventory,
  nixBuildCmd,
  toBuildMatrixEntries,
};
