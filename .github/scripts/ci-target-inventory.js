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
      appendMapping(mapping, `secrets/_templates/${host}.yaml`, field, target.name);
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
