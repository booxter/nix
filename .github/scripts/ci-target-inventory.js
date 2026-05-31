"use strict";

const inventory = require("../../ci-target-inventory.json");

function nixBuildCmd(attr) {
  return `nix build .#${attr} -L --show-trace`;
}

function toBuildMatrixEntries(targets) {
  return targets.map((target) => ({
    name: target.name,
    cmd: nixBuildCmd(target.attr),
    os: target.runner,
  }));
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

function toDiffMatrixEntries(targets) {
  const seen = new Set();
  const entries = [];

  for (const target of targets) {
    const machine = diffMachineForAttr(target.attr);
    if (!machine || seen.has(machine)) {
      continue;
    }

    seen.add(machine);
    entries.push({
      machine,
      name: target.name,
      order: String(entries.length).padStart(3, "0"),
      os: target.runner,
    });
  }

  return entries;
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
  toDiffMatrixEntries,
};
