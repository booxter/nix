{
  inputs,
  lib,
  pkgs,
}:
let
  probe = pkgs.runCommandCC "launchd-certificate-probe" { } ''
    $CC ${./probe.c} -o "$out"
  '';
  arguments = [
    "space argument"
    ""
    "literal $value & 'quotes'"
  ];
  probeArguments = [ "${probe}" ] ++ arguments;
  customBundle = "/certs/company's $bundle.pem";
  blacklist = [ "DigiCert Global Root G2" ];
  fallbackBundle = "${pkgs.cacert.override { inherit blacklist; }}/etc/ssl/certs/ca-bundle.crt";

  # Each fixture pairs a service definition with its expected runtime behavior.
  commonCases = {
    arguments = {
      job.serviceConfig.ProgramArguments = probeArguments;
      expectedArgv = probeArguments;
    };
    program = {
      job.serviceConfig.Program = "${probe}";
      expectedArgv = [ "${probe}" ];
    };
    argv0 = {
      job.serviceConfig = {
        Program = "${probe}";
        ProgramArguments = [ "custom argv0" ] ++ arguments;
      };
      expectedArgv = [ "custom argv0" ] ++ arguments;
    };
    search = {
      job.serviceConfig = {
        ProgramArguments = [ "env" ] ++ probeArguments;
        EnvironmentVariables.PATH = "/no-such-programs";
      };
      expectedArgv = probeArguments;
    };
  }
  //
    lib.mapAttrs
      (_: environment: {
        job.serviceConfig = {
          ProgramArguments = probeArguments;
          EnvironmentVariables = environment;
        };
        expectedArgv = probeArguments;
        expectedEnvironment = environment;
      })
      {
        nix.NIX_SSL_CERT_FILE = "/job/nix.pem";
        ssl.SSL_CERT_FILE = "/job/ssl.pem";
        empty-nix.NIX_SSL_CERT_FILE = "";
        empty-ssl.SSL_CERT_FILE = "";
      };
  daemonCases = commonCases // {
    command = {
      job.command = lib.escapeShellArgs probeArguments;
      expectedArgv = probeArguments;
    };
    script = {
      job.script = "exec ${lib.escapeShellArgs probeArguments}";
      expectedArgv = probeArguments;
    };
  };

  evaluate =
    settings:
    (inputs.nix-darwin.lib.darwinSystem {
      modules = [
        inputs.home-manager.darwinModules.home-manager
        ../../../darwin/_mixins/launchd/certificates.nix
        {
          nixpkgs.pkgs = pkgs;
          nix.enable = false;
          system.stateVersion = 6;
          system.primaryUser = "test";
          users.users.test.home = "/Users/test";

          launchd.daemons = lib.mapAttrs (_: fixture: fixture.job) daemonCases;
          launchd.agents.agent = commonCases.arguments.job;
          launchd.user.agents.user-agent = commonCases.arguments.job;

          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            users.test = {
              home.stateVersion = "26.05";
              launchd.agents = lib.mapAttrs (_: fixture: {
                enable = true;
                config = fixture.job.serviceConfig;
              }) commonCases;
            };
          };
        }
        settings
      ];
    }).config;

  casesFor =
    settings: defaultBundle:
    let
      config = evaluate settings;
      # Use Home Manager's own builder to obtain its final, wrapped plists.
      home = pkgs.runCommand "certificate-test-home" { } ''
        mkdir -p "$out"
        ${config.home-manager.users.test.home.extraBuilderCommands}
      '';
      makeCase = name: fixture: plist: {
        inherit name defaultBundle plist;
        inherit (fixture) expectedArgv;
        expectedEnvironment = fixture.expectedEnvironment or { };
      };
      systemCase =
        jobs: name: fixture:
        makeCase name fixture (pkgs.writeText "${name}.plist" jobs."org.nixos.${name}.plist".text);
    in
    lib.mapAttrsToList (systemCase config.environment.launchDaemons) daemonCases
    ++ [
      (systemCase config.environment.launchAgents "agent" commonCases.arguments)
      (systemCase config.environment.userLaunchAgents "user-agent" commonCases.arguments)
    ]
    ++ lib.mapAttrsToList (
      name: fixture:
      makeCase "home-${name}" fixture "${home}/LaunchAgents/org.nix-community.home.${name}.plist"
    ) commonCases;

  cases = pkgs.writeText "launchd-certificate-cases.json" (
    builtins.toJSON (
      casesFor { } "/etc/ssl/certs/ca-certificates.crt"
      ++ casesFor { environment.variables.NIX_SSL_CERT_FILE = customBundle; } customBundle
      ++ casesFor {
        security.pki.installCACerts = false;
        security.pki.caCertificateBlacklist = blacklist;
      } fallbackBundle
      ++ casesFor {
        security.pki.installCACerts = false;
        environment.variables.NIX_SSL_CERT_FILE = customBundle;
      } customBundle
    )
  );
in
pkgs.runCommand "launchd-certificates"
  {
    sandboxProfile = ''
      (allow file-read* process-exec
        (literal "/bin/wait4path")
        (literal "/usr/bin/getconf")
        (literal "/usr/bin/env"))
    '';
  }
  ''
    ${pkgs.python3}/bin/python ${./runtime.py} ${cases}

    # Prove that disabling the system bundle still respects the root blacklist.
    ${pkgs.openssl}/bin/openssl x509 \
      -in ${pkgs.cacert.unbundled}/etc/ssl/certs/DigiCert_Global_Root_G2:*.crt -out root.pem
    ${pkgs.openssl}/bin/openssl verify -no_check_time \
      -CAfile ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt root.pem
    if ${pkgs.openssl}/bin/openssl verify -no_check_time -CAfile ${fallbackBundle} root.pem; then
      echo "The fallback bundle trusts a blacklisted root" >&2
      exit 1
    fi

    touch "$out"
  ''
