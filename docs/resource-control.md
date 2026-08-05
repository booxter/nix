# Resource Control Policy

Resource limits should keep one faulty workload from exhausting a host without
preventing intentionally large workloads from using available capacity.

## Host Baseline

- Regular NixOS hosts use zram, a small disk-backed swapfile, systemd-oomd
  monitoring for root and user workloads, and bounded user and background
  slices.
- Zram capacity is 25% of RAM, capped at 16 GiB. It has priority 100, ahead of
  the priority-0 disk swapfile.
- Disk swap is an inventory-sized last resort: 2 GiB for small VMs, 4 GiB for
  medium VMs, and 8 GiB for large hosts and builders.
- `user.slice` starts with `MemoryHigh=65%` and `MemoryMax=75%`.
- `background.slice` uses low CPU and I/O weights, `MemoryHigh=50%`, and
  `MemoryMax=70%`.
- Proxmox hosts cap zram at 4 GiB, have no disk swap, and retain
  user/background containment. Root oomd monitoring is disabled. Swapping
  guest memory on the hypervisor would amplify latency across VMs.
- Darwin jobs use launchd's `Background` process class and low-priority I/O.
  Do not treat launchd resource limits as equivalent to Linux cgroups.

`MemoryHigh` is the primary throttling and reclaim control. `MemoryMax` is the
last line of defense, but it does not include swap; `MemorySwapMax` bounds that
separately. CPU weights protect responsiveness under contention; CPU quotas
are reserved for workloads that need a hard throughput ceiling.

## Service Classes

| Class | High | Max | Swap | Tasks | Start | Use |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Lightweight | 512 MiB | 1 GiB | 512 MiB | 128 | 4 min | Small jobs |
| Medium | 2 GiB | 4 GiB | 2 GiB | 512 | 1 hour | Bounded work |
| Heavy | Explicit | Explicit | Explicit | Explicit | Explicit | Large jobs |
| Critical | None | None | None | Explicit | None | Continuity |

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
  diskSwapGiB = 4;

  systemServices = {
    lightweight = [ "jellyfin-exporter" ];
    critical = [ "jellyfin" ];
    heavy.ollama = {
      memoryHigh = "80%";
      memoryMax = "90%";
      memorySwapMax = "8G";
    };
  };

  userServices.lightweight = [ "codex-warmer" ];
};
```

`systemServices` names system-manager units; `userServices` names Linux
systemd user-manager units. Class semantics live in the shared module. Reject
duplicate classifications and incomplete heavy budgets. Do not discover
services by inspecting evaluated timer or launchd configuration.

Swap use is observed as a combined zram and disk total. Alert on sustained
high utilization or page churn; ordinary cold pages in swap are not by
themselves a failure.
