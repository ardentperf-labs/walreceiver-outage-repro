# VACUUM VM reproduction and evidence

This directory is a separate recipe for two fresh, concurrent VM tests of a
VACUUM-related synchronous-replication wait. The current task authorizes the
shared 64 GiB DATA/WAL layout and the 64 GiB DATA plus 32 GiB WAL layout. Keep
PGDG PostgreSQL 18, Patroni strict synchronous replication, pgBackRest Azure
backup/archive/restore, and all other settings matched. Preserve `vm/update/` and all
historical evidence. Do not add Kubernetes, CNPG, AWS, or unrelated settings.

The selected operation is CHECKPOINT followed by `VACUUM (FREEZE)
pgbench_accounts`. Initialize with pgbench `--init-steps=dtGp` so table rows are
left unfrozen and the measured FREEZE has work to perform; this is a necessary
workload setup choice, not a PostgreSQL GUC change. Use that same operation in
both layouts. While `VACUUM (FREEZE)` progress is active, send one SIGTERM to
the standby walreceiver only when the primary's current WAL flush position is
at least 512 MiB (536870912 bytes) ahead of replica replay and pgbench has a
recent positive progress bucket. Measure the gate with
`pg_wal_lsn_diff(pg_current_wal_flush_lsn(), replay_lsn)`; do not substitute
`pg_stat_replication.flush_lsn - replay_lsn`, which is the replica-reported
flush position to replay, or `pg_current_wal_lsn() - replay_lsn`, which uses
the primary WAL insertion position. The retained historical AKS VACUUM runner
used this same primary-flush-to-replay formula. Capture the healthy Terminal 2
state immediately before the signal. Historical evidence remains AKS-only and
is not evidence for either VM run.

## Isolation and preflight

- Use a separate working directory, `.repro.env`, SSH key, browser profile,
  terminal/CDP ports, event records, native logs, and resource group per run.
- A single coordinator checks active experiments, total regional vCPU quota,
  `StandardDsv6Family` quota, regional SKU restrictions, and Network Watcher
  baseline. Reserve eight total vCPUs and eight `StandardDsv6Family` vCPUs
  before provisioning the pair of runs. A `Zone` restriction is not a regional
  prohibition for these non-zonal deployments.
- Each run uses two `Standard_D2s_v6` VMs and four vCPUs. Keep the shared layout
  at one uncached 64 GiB Standard HDD per VM; dedicated layout adds one uncached
  32 GiB WAL disk per VM. Both use Azure Standard HDD caching `None`.
- Keep temporary capture tools outside this repository and durable across a
  workspace reboot. Do not add capture machinery to the four copied scripts or
  README. Do not provision resources for a documentation-only edit.
- Compare the four shell scripts with `vm/update/`; they are intentionally byte-for-
  byte copies. Do not specialize or edit them for the experiment prefix.

## Validate and verify before loading data

Finish script edits before starting a run. Syntax-check shell scripts with
`bash -n`; do not provision resources to validate documentation. The copied
scripts use a common preflight evidence file that must be fresh and show at
least eight available total and family vCPUs and a regional allowed SKU.

For each VM, source its `.repro.env` and identify current Azure managed disk
IDs by LUN and size:

```bash
source .repro.env
az vm show -g "$RG" -n primary --query 'storageProfile.dataDisks[].{name:name,id:managedDisk.id,lun:lun,sizeGiB:diskSizeGB,caching:caching}'
az vm show -g "$RG" -n replica --query 'storageProfile.dataDisks[].{name:name,id:managedDisk.id,lun:lun,sizeGiB:diskSizeGB,caching:caching}'
```

Verify the DATA and WAL relationship on both VMs before pgbench initialization.
DATA must be on a managed disk, separate from OS. In the shared layout,
`/var/lib/postgresql/18/main` and its `pg_wal` path use the same device. In the
dedicated layout, `pg_wal` resolves to `/var/lib/postgresql-wal/18/main` on a
different device. Record the `findmnt` output and current disk IDs privately.

Confirm native log directories under `/var/log/postgresql` are writable by
`postgres` and are on OS disk. The scripts store detached initialization,
operation, and pgbench stdout/stderr, PIDs, and exit markers there. Lost SSH is
a transport failure: reconcile native service state, SQL activity, and logs.
Never blindly retry the VACUUM or resend SIGTERM after an uncertain SSH result.

## Workload and UTC event record

Use README's scale-640 initialization with `--init-steps=dtGp` and pgbench
command (`--client=10`,
`--rate=5`, `--progress=5 --progress-timestamp`). Save full native stdout and
stderr before cleanup. Progress timestamps are Unix epoch milliseconds; use
them rather than observer or SSH arrival times. Verify the pgbench host's UTC
clock against the event recorder.

Record distinct UTC timestamps for pgbench start; VACUUM query start; the
512 MiB primary-current-flush-to-replay signal-gate observation; the last
positive pgbench bucket before the
signal; SIGTERM request; PostgreSQL's native `terminating walreceiver` line;
actual `started streaming WAL` reconnect; native VACUUM service completion;
first positive post-reconnect TPS bucket end; replay catch-up; and final
healthy state. Streaming reconnect and VACUUM completion can occur in either
order. Keep query start from `pg_stat_activity.query_start` separate from
native service completion and later observer reads. Preserve Patroni and
PostgreSQL logs.

Validate the during-VACUUM trigger at the signal request. Record native signal
handling relative to VACUUM completion independently: deferred termination is
an observed outcome, not a failed request gate. Never repeat the signal to force
earlier handling or invent a disconnect from the request timestamp.

Run CHECKPOINT and `VACUUM (FREEZE) pgbench_accounts` as detached unit
`repro-vacuum`, with native log, PID, and exit files named `repro-vacuum.*`
under `/var/log/postgresql` on the OS disk. During active VACUUM, use the
README's read-only Terminal 2 query to confirm all of these at once: a
`pg_stat_progress_vacuum` row for `pgbench_accounts`, a streaming synchronous
replica, and
`pg_wal_lsn_diff(pg_current_wal_flush_lsn(), replay_lsn) >= 536870912`.
The query reports replica-reported `flush_lsn - replay_lsn` and primary
`pg_current_wal_lsn() - replay_lsn` as separate diagnostics, not as the gate.
Also verify all ten pgbench sessions are present. Capture the healthy Terminal
2 observer while the gate is true, then require a recent positive timestamped
five-second pgbench bucket ending after that capture. Immediately before
signaling, re-read the gate and verify that VACUUM progress, the 512 MiB
primary-flush-to-replay distance, synchronous streaming, all ten clients, and
the positive bucket still qualify. If a condition changed during capture,
wait for the complete gate again only while VACUUM remains active. Send exactly
one SIGTERM to the current streaming walreceiver PID. Do not signal after
VACUUM completes or while any condition is false. If the gate, healthy capture,
and positive post-capture progress never coincide before completion, do not
force a late signal; preserve evidence and report the requested condition as
unmet.
After an SSH failure during the one-shot command, reconcile native PostgreSQL
logs and receiver status; never resend SIGTERM or retry VACUUM blindly.

Keep pgbench offered load running after SIGTERM until both native VACUUM
completion (successful `VACUUM` command tag and service exit `0`) and actual
streaming reconnect have been observed, regardless of which occurs first.
Continue through replay catch-up and healthy TPS. Allow at least an hour for
progressing replay, within the bounded run deadline. Report the absence of a
sustained outage honestly. Capture waits that actually occur, including
row-lock waits during VACUUM if present; do not label all waits `SyncRep`
without evidence.

After recovery, stop the recorded pgbench PID with SIGINT. If it is ignored
after 30 seconds, use a bounded SIGTERM on the same PID and reconcile its exit
marker. Native exits 130 or 143 and missing optional final statistics can follow
an intentional stop; retain the full logs and assess progress, SQL result, and
replication evidence. Preserve logs promptly on failed attempts, then clean up.

## Terminal, Portal, and TPS evidence

For each layout, capture the actual README Terminal 2 observer in a real
terminal: (1) healthy writes while VACUUM is active and the signal gate is
ready, before SIGTERM; (2) actual waits at least 30 seconds after the native
PostgreSQL log confirms termination of the signaled walreceiver; and
(3) waits while pgbench runs after actual streaming reconnect. Keep all ten
sessions, headings, and UTC watch timestamp visible. The post-signal capture
may show healthy clients after a fast reconnect. Also record when the native
VACUUM unit completes; it can complete before or after the reconnect capture.
Do not label a pre-SIGTERM terminal view as post-signal; if native termination
is not confirmed, do not claim the 30-second post-signal capture is complete.
Caption the reconnect image with the native approximate reconnect time, not
its watch time. Temporary loopback ttyd/Playwright can capture the real
viewport; review screenshots and xterm accessibility rows rather than
`inner_text()` from canvas.

Capture the current Primary DATA and Replica DATA charts directly in Azure
Portal with Playwright. Match the VM's current disk ID. Use Disk standard
metrics, Average Disk Read and Write Operations/sec, filled stacked areas,
one-minute granularity, and the same custom UTC range on both charts. Start
before pgbench and end after reconnect, replay catch-up, and resumed healthy
TPS. Set the browser and Portal time picker to UTC, verify the chart axis says
UTC+00:00, wait for loading masks to clear and recent data to arrive, then
reopen the time picker and verify `1 minute` before saving. The saved images
must show both filled stacked curves, numeric legend, full time window, and
disk identity. Review both before deleting that run. Do not substitute local
IOPS plots.

Capture timestamped pgbench progress and produce one standalone Matplotlib PNG
per run at 1800×600. Use one panel, blue five-second steps or bars, white
background, light horizontal grid, UTC five-minute ticks, and TPS axis fixed
from 0 to 10 with higher values explicitly reported as clipped. Preserve zero
values and missing intervals as gaps. Match its exact `plot-window.json` bounds
to both DATA charts. Use purple VACUUM start/completion markers, red dash-dot
SIGTERM-request and red dashed native-termination markers, green actual streaming reconnect, and gray first positive TPS bucket
end. Keep colors/line styles consistent; mark approximate times. A positive
bucket reports its interval end, not the exact first completed transaction.
Verify zeros and first positive recovery bucket against the raw native log and
retain raw inputs privately. Do not invent disconnect/reconnect events for a
run where they were not observed.

Save six images per run under `results/`, with these exact prefixes:

- Shared: `pgbackrest-vacuum-shared-`
- Dedicated WAL: `pgbackrest-vacuum-wal-`

For each prefix, use `terminal2-healthy.png`, `terminal2-unhealthy.png`,
`terminal2-reconnected.png`, `primary-data-iops.png`, `replica-data-iops.png`,
and `tps.png`. In the final README, put the three terminal images, both DATA
charts, and then TPS immediately beneath the charts. Use portable relative
paths and the actual chart-window caption. Keep capture commands, helper
installation, and workspace absolute paths out of README.

## Cleanup

Review final Portal captures before deleting each run. Then run its
`./cleanup.sh` immediately and independently. Verify the unique resource group
is absent, including both VMs, OS/DATA/WAL disks, network resources, and that
run's Blob account and contents. Preserve existing Network Watchers and all
unrelated resources. Remove a newly created watcher only with evidence this
experiment created it and no other active run needs it. Record cleanup proof
and UTC time in the final results documentation.
