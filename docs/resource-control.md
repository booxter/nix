# Resource Control Policy

Resource limits should keep one faulty workload from exhausting a host without
preventing intentionally large workloads from using available capacity.

## Host Baseline

- Regular NixOS hosts use zram, systemd-oomd monitoring for root and user
  workloads, and bounded user and background slices.
- Initial zram capacity is 25% of RAM, capped at 16 GiB.
- `user.slice` starts with `MemoryHigh=65%` and `MemoryMax=75%`.
- `background.slice` uses low CPU and I/O weights, `MemoryHigh=50%`, and
  `MemoryMax=70%`.
- Proxmox hosts use a smaller zram ceiling and user/background containment.
  Root oomd monitoring remains disabled until killing a QEMU guest is an
  explicitly accepted failure mode.
- Darwin jobs use launchd's `Background` process class and low-priority I/O.
  Do not treat launchd resource limits as equivalent to Linux cgroups.

`MemoryHigh` is the primary throttling and reclaim control. `MemoryMax` is the
last line of defense. CPU weights protect responsiveness under contention;
CPU quotas are reserved for workloads that need a hard throughput ceiling.

## Service Classes

| Class | Memory high | Memory max | Tasks max | Use |
| --- | ---: | ---: | ---: | --- |
| Lightweight | 512 MiB | 1 GiB | 128 | Probes, sync jobs, reconcilers |
| Medium | 2 GiB | 4 GiB | 512 | Indexers and bounded processing |
| Heavy | Explicit | Explicit | Explicit | Builds, LLMs, databases, backups |
| Critical | None | None | Explicit | Services deliberately kept unconstrained |

Background services run in `background.slice`. Oneshot jobs must also declare
an activation deadline with `TimeoutStartSec`; long-running services use an
appropriate runtime or application-level deadline.

Critical services remain in the normal system slice with no generic memory or
CPU ceiling. They use `ManagedOOMPreference=avoid`, not `omit`, so oomd may
still select them as a last resort. `MemoryLow` and task limits are optional
explicit settings rather than fleet-wide reservations. Classification is
host-specific and should reflect which services are more important to preserve
during resource pressure.

## Nix Interface

Host inventory assigns systemd unit names to classes. Units omitted from the
inventory remain unconstrained beyond the host baseline. Fixed classes use
mergeable lists; heavy services supply explicit budgets:

```nix
resourceControl = {
  systemServices = {
    lightweight = [ "jellyfin-exporter" ];
    critical = [ "jellyfin" ];
    heavy.ollama = {
      memoryHigh = "80%";
      memoryMax = "90%";
    };
  };

  userServices.lightweight = [ "sync-git-mains" ];
};
```

`systemServices` names system-manager units; `userServices` names Linux
systemd user-manager units. Class semantics live in the shared module. Reject
duplicate classifications and incomplete heavy budgets. Do not discover
services by inspecting evaluated timer or launchd configuration.
