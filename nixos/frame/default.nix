{
  inputs,
  lib,
  ...
}:
{
  imports = [ inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series ];

  # systemd's global bpf-restrict-fs link took roughly three minutes to detach
  # during reboot while the kernel waited for a Tasks RCU grace period. No
  # service on this host uses RestrictFileSystems=, so keep the other default
  # LSMs without enabling the BPF LSM solely for that unused systemd feature.
  security.lsm = lib.mkForce [
    "landlock"
    "yama"
  ];
}
