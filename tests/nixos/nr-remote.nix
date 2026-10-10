{ pkgs, ... }:
let
  package = ../../hm/_mixins/dev/nix/pkgs/nr;
  keys = ./backup;
  # Only the review workload is substituted. SSH, package wrappers, and tmux
  # are the same programs used outside the test.
  reviewFixture = pkgs.writeTextFile {
    name = "nr-review-fixture";
    destination = "/bin/nixpkgs-review";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      import os
      import runpy
      import sys
      from pathlib import Path

      directory = Path.home() / "reviews" / sys.argv[2]
      directory.mkdir(parents=True, exist_ok=True)
      os.environ.update(
          NR_TEST_REPORT=str(directory / "report.json"),
          NR_TEST_GATE=str(directory / "finish"),
          NR_TEST_STATUS="7" if sys.argv[2] == "124" else "0",
      )
      runpy.run_path(${builtins.toJSON "${package}/tests/review_stub.py"}, run_name="__main__")
    '';
  };
  nr = pkgs.callPackage package {
    nixpkgs-reviewFull = reviewFixture;
    remoteHost = "server";
    reviewDirectory = "/home/reviewer/src/nixpkgs";
  };
  serverBuilders = "ssh://server-builder aarch64-linux - 2";
  serverLocalBuilders = "ssh://server-local x86_64-linux - 1";
in
pkgs.testers.runNixOSTest {
  name = "nr-remote";

  defaults = {
    users.users.reviewer = {
      isNormalUser = true;
      initialPassword = "unused-test-password";
    };
    environment.systemPackages = [
      pkgs.git
      pkgs.tmux
    ];
  };

  nodes = {
    client = {
      users.users.reviewer.packages = [
        (nr.override { builders = "ssh://client-only x86_64-linux /client/key 1"; })
      ];
      systemd.tmpfiles.rules = [
        "d /home/reviewer/.ssh 0700 reviewer users -"
        "C /home/reviewer/.ssh/id_ed25519 0600 reviewer users - ${keys}/client-key"
      ];
      programs.ssh = {
        knownHosts.server.publicKeyFile = keys + "/server-key.pub";
        extraConfig = ''
          Host server
            BatchMode yes
            StrictHostKeyChecking yes
            ConnectTimeout 5
            ServerAliveInterval 1
            ServerAliveCountMax 3
        '';
      };
    };

    server = {
      users.users.reviewer = {
        packages = [
          (nr.override {
            builders = serverBuilders;
            localBuilders = serverLocalBuilders;
          })
        ];
        openssh.authorizedKeys.keyFiles = [ (keys + "/client-key.pub") ];
      };
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys + "/server-key";
        mode = "0600";
      };
      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
        settings = {
          PasswordAuthentication = false;
          ClientAliveInterval = 1;
          ClientAliveCountMax = 2;
        };
      };
    };
  };

  testScript = ''
    SERVER_BUILDERS = ${builtins.toJSON serverBuilders}
    SERVER_LOCAL_BUILDERS = ${builtins.toJSON serverLocalBuilders}
  ''
  + builtins.readFile ./nr-remote/test.py;
}
