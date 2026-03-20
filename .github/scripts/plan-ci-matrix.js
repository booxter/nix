"use strict";

function isDocPath(path) {
  return path === "README.md" || path.startsWith("docs/") || path.endsWith(".md");
}

function isDocsOnly(paths) {
  return paths.length > 0 && paths.every(isDocPath);
}

function filterNonDocPaths(paths) {
  return paths.filter((p) => !isDocPath(p));
}

function isOnlyUnder(paths, prefix) {
  return paths.length > 0 && paths.every((p) => p.startsWith(prefix));
}

async function getChangedPaths({ context, github }) {
  const changedFiles = await github.paginate(github.rest.pulls.listFiles, {
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: context.payload.pull_request.number,
    per_page: 100,
  });
  return changedFiles.map((f) => f.filename);
}

function scopeBuildInclude({ paths, include }) {
  if (isOnlyUnder(paths, "darwin/")) {
    return {
      include: include.filter((item) => item.os.startsWith("macos-")),
      reason: "darwin",
    };
  }
  if (isOnlyUnder(paths, "nixos/")) {
    return {
      include: include.filter((item) => !item.os.startsWith("macos-")),
      reason: "nixos",
    };
  }
  return { include, reason: "full" };
}

function selectMachineSpecific({ paths, include, mapping, field }) {
  const selected = new Set();
  let onlyMachineSpecific = paths.length > 0;

  for (const filePath of paths) {
    let matched = false;
    for (const entry of mapping) {
      if (filePath.startsWith(entry.prefix)) {
        for (const name of entry[field]) {
          selected.add(name);
        }
        matched = true;
        break;
      }
    }
    if (!matched) {
      onlyMachineSpecific = false;
      break;
    }
  }

  if (onlyMachineSpecific && selected.size > 0) {
    return {
      include: include.filter((item) => selected.has(item.name)),
      machineSpecific: true,
    };
  }

  return { include, machineSpecific: false };
}

module.exports = {
  filterNonDocPaths,
  getChangedPaths,
  isDocsOnly,
  isOnlyUnder,
  scopeBuildInclude,
  selectMachineSpecific,
};
