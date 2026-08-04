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
- Proxmox hosts cap zram at 4 GiB and retain user/background containment. Root
  oomd monitoring is disabled.
- Darwin jobs use launchd's `Background` process class and low-priority I/O.
  Do not treat launchd resource limits as equivalent to Linux cgroups.

`MemoryHigh` is the primary throttling and reclaim control. `MemoryMax` is the
last line of defense. CPU weights protect responsiveness under contention;
CPU quotas are reserved for workloads that need a hard throughput ceiling.

## Service Classes

| Class | High | Max | Tasks | Start | Use |
| --- | ---: | ---: | ---: | ---: | --- |
| Lightweight | 512 MiB | 1 GiB | 128 | 15 min | Probes, sync, reconcilers |
| Medium | 2 GiB | 4 GiB | 512 | 1 hour | Indexers and bounded processing |
| Heavy | Explicit | Explicit | Explicit | Explicit | Large explicit workloads |
| Critical | None | None | Explicit | None | Unconstrained continuity services |

Background services run in `background.slice`. Heavy oneshot jobs declare an
activation deadline with `TimeoutStartSec`; long-running services use an
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
