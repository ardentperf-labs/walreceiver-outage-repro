# Experimental conditions

## No disconnect (control)

Run the same workload without terminating the walreceiver.

![Initial waits](no-disconnect-terminal2-healthy.png)

![Wait events after VACUUM](no-disconnect-terminal-after.png)

Final waits at approximately 23:07:31 UTC; no disconnect occurred.

![Final wait events](no-disconnect-terminal2-final.png)

Azure read/write IOPS (one-minute granularity selected), 22:31–23:09 UTC on 2026-10-18 (East US, Standard_D2s_v4); VACUUM was active by 22:35:02 and completed at 22:39:30. Replay caught up around 23:06:03; streaming remained connected and pgbench reported no zero-TPS intervals through 23:08:15.

![Primary DATA disk IOPS](no-disconnect-primary-data-iops.png)

![Replica DATA disk IOPS](no-disconnect-replica-data-iops.png)

![TPS aligned with Azure IOPS timestamps](no-disconnect-tps.png)

## recovery_prefetch=off

Run the same test with `recovery_prefetch=off`, disconnecting when lag reaches 512 MB during VACUUM or five minutes after VACUUM starts, whichever comes first, and capture wait events one minute after disconnect regardless of how many sessions are waiting on `SyncRep`.

![Initial waits](recovery-prefetch-off-terminal2-healthy.png)

Waits at 00:25:11 UTC, about one minute after disconnect.

![Wait events after disconnect](recovery-prefetch-off-terminal-after.png)

Streaming reconnected at approximately 00:24:12 UTC.

![Wait events after reconnect](recovery-prefetch-off-terminal2-reconnected.png)

Azure read/write IOPS (one-minute granularity), 00:15–00:28 UTC on 2026-10-19 (East US, Standard_D2s_v4); VACUUM started at 00:19:08 and completed by approximately 00:23:52. The disconnect was at 00:24:11, using the five-minute fallback, and streaming reconnected around 00:24:12. Sampled lag peaked at 102 MiB and pgbench reported no zero-TPS intervals.

![Primary DATA disk IOPS](recovery-prefetch-off-primary-data-iops.png)

![Replica DATA disk IOPS](recovery-prefetch-off-replica-data-iops.png)

![TPS aligned with Azure IOPS timestamps](recovery-prefetch-off-tps.png)

## Preferred durability

Run the same test with `dataDurability: preferred` and the default `wal_sender_timeout`, applying this Cluster patch before preparation:

```bash
kubectl patch cluster postgres --type merge --patch-file conditions/preferred.yaml
```

![Initial waits](preferred-terminal2-healthy.png)

Waits at 22:39:41 UTC, about 20 seconds after disconnect.

![Wait events shortly after disconnect](preferred-terminal-after-15s.png)

Waits at 22:40:40 UTC, about one minute after the previous capture.

![Wait events about 75 seconds after disconnect](preferred-terminal-after-75s.png)

Streaming reconnected at approximately 23:15:26 UTC.

![Wait events after reconnect](preferred-terminal2-reconnected.png)

Azure read/write IOPS (one-minute granularity selected), 22:31–23:17 UTC on 2026-10-18 (West US 2, Standard_D2s_v6); VACUUM started at 22:39:08 and completed at 22:44:07; the disconnect was at 22:39:21. Streaming reconnected around 23:15:26; the first positive TPS bucket ended at 23:15:31. Synchronous replication stayed enabled, with 433 zero-TPS intervals (about 36 minutes).

![Primary DATA disk IOPS](preferred-primary-data-iops.png)

![Replica DATA disk IOPS](preferred-replica-data-iops.png)

![TPS aligned with Azure IOPS timestamps](preferred-tps.png)

## Preferred durability with streaming readiness

Run the same test with `dataDurability: preferred` and default streaming readiness (no lag limit), using this Cluster patch before preparation:

```bash
kubectl patch cluster postgres --type merge --patch-file conditions/preferred-streaming.yaml
```

![Initial waits](preferred-streaming-terminal2-healthy.png)

Waits at 22:35:41 UTC, about 15 seconds after disconnect, showing `SyncRep`.

![Wait events about 15 seconds after disconnect](preferred-streaming-terminal-after-15s.png)

Waits at 22:36:41 UTC, about one minute after the previous capture, with transactions flowing again.

![Wait events about 75 seconds after disconnect](preferred-streaming-terminal-after-75s.png)

Streaming reconnected at approximately 23:09:08 UTC.

![Wait events after reconnect](preferred-streaming-terminal2-reconnected.png)

Azure read/write IOPS (one-minute granularity selected), 22:31–23:12 UTC on 2026-10-18 (West US 2, Standard_D2s_v6); VACUUM started at 22:35:04 and completed at 22:39:47; the disconnect was at 22:35:26. Synchronous replication was relaxed at 22:35:59, about 34 seconds later; the first positive TPS bucket ended at 22:36:01. Streaming reconnected around 23:09:08.

![Primary DATA disk IOPS](preferred-streaming-primary-data-iops.png)

![Replica DATA disk IOPS](preferred-streaming-replica-data-iops.png)

![TPS aligned with Azure IOPS timestamps](preferred-streaming-tps.png)
