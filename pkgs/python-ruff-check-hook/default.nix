{
  lib,
  makeSetupHook,
  ruff,
}:

makeSetupHook {
  name = "python-ruff-check-hook";
  substitutions = {
    ruff = lib.getExe ruff;
    ruffConfig = ../../ruff.toml;
  };
} ./setup-hook.sh
