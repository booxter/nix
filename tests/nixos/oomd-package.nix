{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "oomd-package";
  nodes.machine.environment.variables.GTEST_FILTER = pkgs.oomd.kernelTestFilter;
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    # Complete the build's upstream tests with the cases needing a real kernel
    # and filesystem. The rest already run in the package's checkPhase.
    machine.succeed("cd ${pkgs.oomd.tests}/share; for test in ${pkgs.oomd.tests}/bin/*; do $test || exit; done")
  '';
}
