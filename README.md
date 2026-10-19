# walreceiver disconnect during a write burst

An **8 GiB** pgbench table, `VACUUM (FREEZE)`, and one SIGTERM to the replica's
walreceiver. Standard pgbench prints `--progress=5` so the write outage is visible
as repeated `0.0 tps` lines.

CloudNativePG runs PostgreSQL **18** on two separate AKS nodes (`Standard_D2s_v4`,
2 CPUs / 8 GiB each). Each instance has separate 64 GiB **Standard HDD** DATA and
WAL disks, host caching disabled, rated up to **500 IOPS**. WAL archives go to
**Azure Blob Storage**. No metrics stack.

## Setup

Requires Bash, Azure CLI logged in to your subscription, and kubectl:

```bash
./provision.sh                 # LOCATION=eastus by default
source .repro.env
./prepare.sh                   # load and catch up
```

This uses CNPG 1.30.1's [built-in Barman integration](https://cloudnative-pg.io/docs/1.30/appendixes/backup_barmanobjectstore/)
to keep the reproduction small. That integration is deprecated upstream but
remains functional in this release. The PostgreSQL image floats at
`ghcr.io/cloudnative-pg/postgresql:18`.

Preparation uses `--initialize --scale=640 --init-steps=dtGp`. Capital `G`
generates unfrozen rows; lowercase `g` uses `COPY FREEZE` and would defeat this
workload. `p` adds the standard primary keys.
The Cluster YAML configures synchronous replication and the Blob backup
destination. Preparation waits for replay to catch up.

On this fresh cluster, `postgres-1` is the primary and `postgres-2` the replica.
Check their roles and separate nodes:

```bash
kubectl get pods -l cnpg.io/cluster=postgres -o wide --show-labels
```

## Terminal 1: run pgbench

```bash
source .repro.env
kubectl exec postgres-1 -c postgres -- pgbench --username=postgres \
  --builtin=tpcb-like --no-vacuum --client=10 --rate=5 --time=14400 --progress=5 postgres
```

Wait for several healthy progress lines at approximately 5 TPS.

## Terminal 2: observe waits

```bash
source .repro.env
echo "SELECT pid, wait_event_type, wait_event, clock_timestamp()-xact_start AS age FROM pg_stat_activity WHERE application_name='pgbench'; \watch 1" | kubectl exec -i postgres-1 -c postgres -- psql -X -U postgres
```

## Terminal 3: observe lag

```bash
source .repro.env
echo 'SELECT pg_size_pretty(flush_lsn - replay_lsn) AS replay_lag FROM pg_stat_replication; \watch 1' | kubectl exec -i postgres-1 -c postgres -- psql -X -U postgres
```

The row disappears while the replica is disconnected from streaming.

## Terminal 4: write burst, then disconnect

```bash
source .repro.env
kubectl exec postgres-1 -c postgres -- psql -X -U postgres -c CHECKPOINT -c 'VACUUM (FREEZE) pgbench_accounts' &
```

VACUUM and pgbench use the default cost delay and synchronous commit settings.

Wait for replay lag to reach **512 MB** while VACUUM is running and pgbench
is still completing writes. Then send **one** SIGTERM to the streaming walreceiver:

```bash
pid=$(kubectl exec postgres-2 -c postgres -- psql -X -U postgres -Atc \
  "SELECT pid FROM pg_stat_wal_receiver WHERE status='streaming'")
test -n "$pid" && kubectl exec postgres-2 -c postgres -- sh -c 'kill -TERM "$1"' sh "$pid"
```

Watch for `0.0 tps`, `IPC / SyncRep` waits, and archive recovery in the replica log:

```bash
kubectl logs postgres-2 -c postgres --since=2m | tail -20
```

Keep pgbench running until streaming and TPS resume. Duration depends on archive
backlog and disk behavior. Ordinary `VACUUM (FREEZE)` is compatible with concurrent
pgbench DML; some clients may queue on row locks held by transactions waiting for
synchronous replication. For a control, repeat on a fresh cluster without SIGTERM.

## Cleanup

**Delete the cluster when finished.** Stopping pgbench does not stop billing:

```bash
./cleanup.sh
```

This deletes the unique resource group, AKS nodes, all four PostgreSQL disks,
and the Blob account including backups. To find those disks in Azure Portal:

```bash
kubectl get pv -o custom-columns=CLAIM:.spec.claimRef.name,DISK:.spec.csi.volumeHandle
```

## Experimental conditions

| Run | Description |
| --- | --- |
| Main reproduction | Write burst followed by walreceiver SIGTERM, with required synchronous replication. |
| No disconnect (control) | The same workload without terminating the walreceiver. |
| `recovery_prefetch=off` | Disable recovery prefetch; disconnect at 512 MB of lag or five minutes after VACUUM starts. |
| Preferred durability | Use `dataDurability: preferred` with default readiness. |
| Preferred durability with streaming readiness | Use preferred durability and streaming readiness with defaults. |

See the [test conditions and screenshots](conditions/README.md).

## Screenshots

### Waits before disconnect

![Healthy pgbench sessions before disconnect](results/terminal2-healthy.png)

### Waits after disconnect

![Stalled pgbench sessions after disconnect](results/terminal2-unhealthy.png)

### Waits after reconnect

Streaming reconnected at approximately 23:06:51 UTC.

![Wait events after reconnect](results/terminal2-reconnected.png)

### Azure disk IOPS

Azure read/write IOPS (one-minute granularity selected), 22:31–23:13 UTC on 2026-10-18 (East US, Standard_D2s_v4).
VACUUM was active by 22:35:54; the disconnect was around 22:39:02; VACUUM
completed at 22:39:50. Streaming reconnected around 23:06:51; the first positive
TPS bucket ended at 23:06:56, after 333 zero-TPS intervals (about 28 minutes).

![Primary DATA disk IOPS](results/primary-data-iops.png)

![Replica DATA disk IOPS](results/replica-data-iops.png)

![TPS aligned with Azure IOPS timestamps](results/tps.png)
