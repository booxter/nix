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

Background services run in `background.slice`. Oneshot jobs must also declare
an activation deadline with `TimeoutStartSec`; long-running services use an
appropriate runtime or application-level deadline. Critical services may use
memory protection and oomd avoidance, but only through explicit configuration.

## Nix Interface

Resource policy stays adjacent to each service and expands to ordinary systemd
settings. A shared helper should support both NixOS `serviceConfig` and Home
Manager `Service` values:

```nix
Service = resourceControl.background {
  memoryHigh = "512M";
  memoryMax = "1G";
  timeoutStartSec = "30m";
};
```

Do not discover or rewrite services by inspecting the evaluated timer or
launchd configuration. Migrate in-tree services explicitly, and document
host-specific exceptions beside their service definitions.
