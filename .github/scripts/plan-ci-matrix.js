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

function filterSelectionPaths(paths, { ignore = [] } = {}) {
  const ignored = new Set(ignore);
  return filterNonDocPaths(paths).filter((p) => !ignored.has(p));
}

function defaultSelectionPathFilter(paths) {
  return filterSelectionPaths(paths, { ignore: ["eslint.config.js"] });
}

async function planMatrix({
  context,
  github,
  eventName,
  fullMatrix,
  machinePathMap,
  mappingField,
  skipWhenDocsOnly = false,
  skipWhenSelectionEmpty = false,
  skipWhenOnlyDarwin = false,
  scopeByOs = false,
  selectionPathFilter = defaultSelectionPathFilter,
}) {
  const paths = await getChangedPaths({ context, github });
  const docsOnly = isDocsOnly(paths);
  const selectionPaths = selectionPathFilter(paths);

  const result = {
    paths,
    docsOnly,
    ignoredOnly: false,
    selectionPaths,
    scopeReason: "full",
    machineSpecific: false,
    matrix: { include: fullMatrix.include },
  };

  if (eventName !== "pull_request") {
    return result;
  }

  if (docsOnly && skipWhenDocsOnly) {
    return { ...result, matrix: { include: [] } };
  }

  if (skipWhenSelectionEmpty && selectionPaths.length === 0) {
    return { ...result, ignoredOnly: true, scopeReason: "ignored", matrix: { include: [] } };
  }

  if (skipWhenOnlyDarwin && isOnlyUnder(selectionPaths, "darwin/")) {
    return { ...result, matrix: { include: [] }, scopeReason: "darwin" };
  }

  let candidateInclude = fullMatrix.include;
  if (scopeByOs) {
    const scoped = scopeBuildInclude({ paths: selectionPaths, include: fullMatrix.include });
    candidateInclude = scoped.include;
    result.scopeReason = scoped.reason;
  }

  const selection = selectMachineSpecific({
    paths: selectionPaths,
    include: candidateInclude,
    mapping: machinePathMap,
    field: mappingField,
  });

  return {
    ...result,
    machineSpecific: selection.machineSpecific,
    matrix: { include: selection.include },
  };
}

module.exports = {
  filterSelectionPaths,
  filterNonDocPaths,
  getChangedPaths,
  isDocsOnly,
  isOnlyUnder,
  planMatrix,
  scopeBuildInclude,
  selectMachineSpecific,
};
