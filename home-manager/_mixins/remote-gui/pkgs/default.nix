{ pkgs }:
let
  launchctlFailureStub = pkgs.writeShellScript "launchctl-failure-stub" ''
    exit 1
  '';
  waylandSocketTestStub = pkgs.writeText "wayland-socket-test-stub.py" ''
    import signal
    import socket
    import sys

    listener = socket.socket(socket.AF_UNIX)
    listener.bind(sys.argv[1])
    listener.listen()
    signal.pause()
  '';
  launchctlTestStub = pkgs.writeShellScript "launchctl-test-stub" ''
    printf '%s\n' "$*" >"$LAUNCHCTL_LOG"
    "${pkgs.python3}/bin/python3" ${waylandSocketTestStub} \
      "$COCOA_WAY_RUNTIME_DIR/wayland-8" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$LAUNCHCTL_SOCKET_PID_FILE"
  '';
  waypipeTestStub = pkgs.writeShellScript "waypipe-test-stub" ''
    printf '%s\n' "$*" >"$WAYPIPE_LOG"
    printf '%s/%s\n' "$XDG_RUNTIME_DIR" "$WAYLAND_DISPLAY" >"$WAYLAND_LOG"
    while IFS= read -r _; do :; done
  '';
  mkRunner =
    {
      description,
      name,
      runtimeInputs ? [ ],
      transport,
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.openssh ] ++ runtimeInputs;
      text = ''
        export RUN_NIXPKGS_PROGRAM_NAME=${name}
        export RUN_NIXPKGS_TRANSPORT=${transport}
        ${builtins.readFile ./run-nixpkgs.sh}
      '';

      derivationArgs = {
        doCheck = true;
        nativeCheckInputs = [
          pkgs.bats
          pkgs.python3
          pkgs.shellcheck
        ];
      };
      checkPhase = ''
        runHook preCheck
        bash -n "$target"
        ${pkgs.lib.getExe pkgs.shellcheck} "$target"
        RUN_NIXPKGS_BIN="$target" \
          RUN_NIXPKGS_LAUNCHCTL_FAILURE_STUB=${launchctlFailureStub} \
          RUN_NIXPKGS_LAUNCHCTL_STUB=${launchctlTestStub} \
          RUN_NIXPKGS_TEST_TRANSPORT=${transport} \
          RUN_NIXPKGS_WAYPIPE_STUB=${waypipeTestStub} \
          ${pkgs.lib.getExe pkgs.bats} --print-output-on-failure ${./run-nixpkgs.bats}
        runHook postCheck
      '';

      meta = {
        inherit description;
        license = pkgs.lib.licenses.mit;
        maintainers = with pkgs.lib.maintainers; [ booxter ];
        mainProgram = name;
      };
    };
in
{
  xrun-nixpkgs = mkRunner {
    name = "xrun-nixpkgs";
    transport = "x11";
    description = "Build a Linux nixpkgs package remotely and run it through SSH X11 forwarding";
  };

  wrun-nixpkgs = mkRunner {
    name = "wrun-nixpkgs";
    runtimeInputs = [ pkgs.socat ];
    transport = "waypipe";
    description = "Build a Linux nixpkgs package remotely and run it through Cocoa-Way and Waypipe";
  };
}
