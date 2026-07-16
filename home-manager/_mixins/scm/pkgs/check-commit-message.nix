{
  git,
  lib,
  python3,
  python3Packages,
  writeShellApplication,
  writeShellScript,
}:
let
  testRepoCommitMsgHook = writeShellScript "test-repo-commit-msg-hook" ''
    touch repo-hook-ran
  '';
in
writeShellApplication {
  name = "check-commit-message";
  text = ''
    exec ${python3}/bin/python3 ${./check_commit_message.py} "$@"
  '';
  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [
      git
      python3Packages.pytest
    ];
  };
  checkPhase = ''
    runHook preCheck
    check_dir=$(mktemp -d)
    cp ${./check_commit_message.py} "$check_dir/check_commit_message.py"
    cp ${./test_check_commit_message.py} "$check_dir/test_check_commit_message.py"
    cd "$check_dir"
    pytest -q -p no:cacheprovider test_check_commit_message.py

    git init --quiet hook-test
    mkdir hook-test/custom-hooks
    ln -s ${testRepoCommitMsgHook} hook-test/custom-hooks/commit-msg
    git -C hook-test config user.name Test
    git -C hook-test config user.email test@example.com
    git -C hook-test config commit.gpgSign false
    git -C hook-test config core.hooksPath custom-hooks
    git -C hook-test config hook.commit-message-test.event commit-msg
    git -C hook-test config hook.commit-message-test.command \
      "${python3}/bin/python3 $check_dir/check_commit_message.py"
    git -C hook-test commit --quiet --allow-empty \
      -m 'Accept a formatted message' \
      -m 'This body fits within the configured physical line limit.'
    test -e hook-test/repo-hook-ran

    long_body='This deliberately long body line must be rejected before Git creates another commit in the test repository.'
    if git -C hook-test commit --quiet --allow-empty \
      -m 'Reject an unformatted message' -m "$long_body"; then
      echo 'expected the named commit-msg hook to reject long prose' >&2
      exit 1
    fi
    test "$(git -C hook-test rev-list --count HEAD)" -eq 1
    runHook postCheck
  '';

  meta = {
    description = "Validate the global Git commit message format";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "check-commit-message";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
