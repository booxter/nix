"use strict";

function nixBuildCmd(attr) {
  return `nix build .#${attr} -L --show-trace`;
}

function nixChecksBuildCmd(system, checks) {
  const attributes = checks.map(
    (check) => `".#checks.${system}.${check}"`,
  );
  return `nix build --keep-going --no-link -L --show-trace ${attributes.join(" ")}`;
}

function checkRunner(system) {
  const runners = {
    "aarch64-darwin": "nix-ci-darwin",
    "x86_64-linux": "nix-ci",
  };
  const runner = runners[system];
  if (!runner) {
    throw new Error(`No check runner configured for ${system}`);
  }
  return runner;
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
      attr: target.attr,
      name: target.name,
      cmd: nixBuildCmd(target.attr),
      diff_machine: shouldDiff ? machine : "",
      diff_order: shouldDiff ? String(index).padStart(3, "0") : "",
      os: target.runner,
    };
  });
}

function toCheckBatchMatrixEntries(checksBySystem) {
  return Object.entries(checksBySystem).flatMap(([system, groups]) => {
    if (groups.batch.length === 0) {
      return [];
    }
    return [
      {
        cmd: nixChecksBuildCmd(system, groups.batch),
        name: `Other checks (${system})`,
        os: checkRunner(system),
      },
    ];
  });
}

function toNixosTestMatrixEntries(checksBySystem) {
  return Object.entries(checksBySystem).flatMap(([system, groups]) =>
    groups.nixosTests.map((check) => ({
      cmd: nixChecksBuildCmd(system, [check]),
      name: `${check} (${system})`,
      os: checkRunner(system),
    })),
  );
}

module.exports = {
  nixBuildCmd,
  nixChecksBuildCmd,
  toBuildMatrixEntries,
  toCheckBatchMatrixEntries,
  toNixosTestMatrixEntries,
};
