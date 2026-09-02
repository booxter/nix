# shellcheck shell=bash

pythonRuffCheckHook() {
    echo "Executing pythonRuffCheckHook"

    local -a paths=()
    concatTo paths pythonRuffCheckPaths
    if ((${#paths[@]} == 0)); then
        [[ ! -e src ]] || paths+=(src)
        [[ ! -e tests ]] || paths+=(tests)
    fi
    if ((${#paths[@]} == 0)); then
        echo "pythonRuffCheckHook requires pythonRuffCheckPaths or a src/tests directory" >&2
        return 1
    fi

    @ruff@ format --check --no-cache --config @ruffConfig@ "${paths[@]}"
    @ruff@ check --no-cache --config @ruffConfig@ "${paths[@]}"

    echo "Finished pythonRuffCheckHook"
}

preCheckHooks+=(pythonRuffCheckHook)
