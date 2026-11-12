{ sops }:
sops.overrideAttrs (old: {
  # SOPS 3.13.3 only reads age plugin PINs from /dev/tty. User services
  # need a local graphical prompt; remove this patch when upstream supports it.
  patches = (old.patches or [ ]) ++ [ ./askpass.patch ];
  preCheck = (old.preCheck or "") + ''
    go test ./age ./keyservice
  '';
})
