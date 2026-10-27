# VM reproduction and evidence

This directory contains the self-contained PGDG/Patroni/pgBackRest VM recipe
and the completed shared-DATA/WAL and dedicated-WAL parallel tests. The current
request is documentation/file organization only. Do not provision or rerun Azure
experiments to validate documentation, script syntax, or image paths. Preserve
all historical evidence. General repository instructions also apply; the VM
workflow here replaces Kubernetes-specific capture steps for this directory.

## Scope and run isolation

- Use two Ubuntu `Standard_D2s_v6` VMs per run. Shared: one uncached 64 GiB
  Standard HDD for DATA/WAL per VM. Dedicated: 64 GiB DATA plus 32 GiB WAL,
  both uncached Standard HDDs. Keep PGDG PostgreSQL 18, Patroni strict sync,
  pgBackRest Azure Blob backup/archive/restore, and all other settings matched.
- Change only settings necessary for the documented reproduction. Keep memory,
  checkpoints, timeouts, autovacuum, and recovery prefetch at their defaults.
  Patroni supplies its own replication defaults; distinguish those from bare
  PostgreSQL defaults when reporting settings.
- For an explicitly authorized experiment, use one copy of this directory and
  one `.repro.env`/SSH identity per run. Browser profiles, ttyd/CDP ports, native
  logs, resource groups, status metadata, and deadlines must also be isolated.
  Keep temporary capture/runners outside the repository and durable across a
  workspace reboot. Do not add capture tooling to these scripts or README.
- One coordinator checks existing experiments, quotas, SKU restrictions, and
  Network Watchers before provisioning. Reserve four total regional vCPUs and
  four `StandardDsv6Family` vCPUs per run, eight of each for two concurrent runs.
  Treat `Location` restrictions as regional prohibitions, not `Zone` restrictions.
  Avoid duplicate `az vm list-skus` calls: the credential wrapper has a global
  command lock. Do not bypass or modify that wrapper.
- Preserve pre-existing Network Watchers and unrelated resources. Use asynchronous
  Azure deployment/deletion requests with short status polls, as in the scripts.

## Validate before provisioning

Finish edits before launching scripts. Run `bash -n` on all shell scripts and
compile temporary Python in memory. Exercise subprocess helpers and event-logger
call shapes with harmless local commands. Never edit an executing shell script.
Freeze one validated script set per run; compare the two layouts' settings.

Verify DATA/WAL/OS devices before initializing the workload. DATA must be distinct
from OS; shared DATA and WAL must resolve to the same device; dedicated DATA and
WAL must differ. Resolve protected PostgreSQL paths using `sudo readlink -e` and
inspect mounts using `sudo findmnt` on the resolved paths. Confirm the postgres
user can write native logs under `/var/log/postgresql` on the OS disk.

Select current managed DATA disks by size/LUN, never old disk IDs:

```bash
source .repro.env
az vm show -g "$RG" -n primary --query 'storageProfile.dataDisks[].{name:name,id:managedDisk.id,lun:lun,sizeGiB:diskSizeGB,caching:caching}'
az vm show -g "$RG" -n replica --query 'storageProfile.dataDisks[].{name:name,id:managedDisk.id,lun:lun,sizeGiB:diskSizeGB,caching:caching}'
```

DATA is 64 GiB at LUN 0; the dedicated layout adds 32 GiB WAL at LUN 1.
Chart only DATA, never WAL or OS. Compare current IDs with final Portal images.

Smoke-check and visually review the real terminal and Portal paths before the
measured workload. A blank early metric chart is only a control/path check.
Do not add human-approval timers that delete healthy VMs during smoke checks.
Bound the complete experiment and cleanup; allow at least an hour for recovery
while replay is progressing, rather than discarding it after 15 minutes.

## Workload, native logs, and event times

Use README's exact detached systemd initialization, UPDATE, and pgbench commands.
Preserve native stdout/stderr, PIDs, and exit markers from
`/var/log/postgresql/repro-*` before deletion. SSH failure is a transport failure;
reconcile native unit state, SQL activity, and completion output before deciding
an operation failed. Never blindly retry UPDATE or resend a signal.

The measured operation is CHECKPOINT + 5% UPDATE. Send one **SIGTERM** to the
replica walreceiver only after `UPDATE 3200000`, native UPDATE exit `0`, and a
full positive pgbench reporting interval after completion. Capture healthy waits
before that signal. These experiments do not use SIGKILL. Do not substitute
fixed elapsed-time or matched-backlog signaling without a new user request.

Record UTC clocks and distinct events: pgbench start, UPDATE query start,
UPDATE completion, signal request, native walreceiver termination, actual
streaming reconnect, first positive reporting bucket, and final healthy state.
Use `pg_stat_activity.query_start` for UPDATE start. Preserve the native unit
journal for a successful completion bound, separate from the later observer read:

```bash
./ssh.sh primary 'sudo journalctl -u repro-update.service --no-pager -o json'
```

Use PostgreSQL's native `terminating walreceiver` and `started streaming WAL`
messages for signal/reconnect timestamps. A positive TPS bucket does not prove
streaming has reconnected. Patroni synchronous confirmation can follow the
native streaming event; preserve both times and allow bounded read-only retries.
A selector of `*` still requires a synchronous standby; verify strict mode and
`synchronous_commit=on` rather than treating that selector alone as relaxation.

Capture WAL generation, sent, written, flushed, and replay positions separately.
A small receive-to-replay gap does not imply a small primary-to-replica backlog.
PG18 receiver fields are `written_lsn` and `flushed_lsn`. Empty receiver/replication
views are expected during disconnection; JSON aggregates must handle empty rows.
Preserve available default PostgreSQL/pgBackRest logs, backup/archive checks,
settings audits, and optional read-only I/O counters. Do not enable extra logging
GUCs or put capture output on measured disks merely to support tooling.

Keep offered load running through reconnect, replay catch-up, and healthy TPS.
Then stop the recorded native pgbench PID with SIGINT. If ignored for 30 seconds,
use bounded SIGTERM fallback and reconcile its exit marker. Exit 130/143 without
an optional final statistics block can follow intentional stops; retain complete
native logs and assess the measured window rather than extending cloud runtime
just to obtain a summary. Save native evidence promptly on failed attempts and
clean up immediately after reconciliation.

## Real terminal captures

Run README's Terminal 2 SSH/psql observer in a real terminal. Temporary loopback
`ttyd` and Playwright may be used; do not recreate its table from text. A
1500 × 650 viewport, font size 20, and screen-reader mode work well. xterm uses
canvas: review screenshots and accessibility rows instead of waiting on canvas
`inner_text()`. Stop any automatically installed ttyd service and use only the
temporary loopback listener.

For each run save three real viewports, with headings, all ten sessions, and UTC
watch timestamp visible:

1. Healthy writes after UPDATE, before the signal.
2. Approximately 30–40 seconds after the single SIGTERM. Capture actual waits;
   a fast reconnect can show healthy sessions instead of prolonged `SyncRep`.
3. After actual streaming reconnect, while pgbench is running. Caption this
   image with the native approximate reconnect UTC time, independently of the
   watch/capture timestamp.

Stop the terminal server and browser after these captures.

## Azure Portal DATA charts

Use Playwright to capture Azure Portal itself, not locally plotted IOPS. On each
current DATA disk's **Monitoring → Metrics** page configure:

- **Disk standard metrics** namespace.
- **Disk Read Operations/sec(Preview)** and **Disk Write Operations/sec(Preview)**,
  both **Average**, using filled **stacked area** series (Portal may say Area chart).
- A common custom UTC range for the two disks, starting before pgbench and ending
  after replay catch-up and resumed writes. Include the whole experiment.
- Set the browser timezone and Portal picker to UTC; verify the UTC axis label.
- In the top-right time-range panel, explicitly set **Time granularity → 1 minute**.
- Titles identifying Primary DATA or Replica DATA, read/write IOPS, and one-minute
  averages. A title alone does not change aggregation or granularity.

Controls may be in an iframe; locate the frame by the current disk name and Add
metric button. Allow recent metrics to arrive, refresh after recovery, and wait
for loading masks and spinners to disappear. Before the final screenshot reopen
the time picker, verify 1 minute again, close it, and let the chart finish loading.
Keep the full granularity label visible, using a tooltip if necessary. A
1800 × 1100 viewport works well; account headers may be clipped without cropping
metric data. Require visible stacked filled curves and numeric legends, and
review both saved PNGs before cleanup. Late recovery minutes can arrive several
minutes after older curves: those older curves are not proof of complete data.

The retained shared-repeat replica genuinely had no series in Portal or API.
Keep its `--` view labeled **metrics unavailable**, never zero measured IOPS.
Do not substitute invented curves or historical screenshots. If a future capture
fails, preserve the evidence, report the limitation, and clean up the failed
attempt; do not keep VMs running indefinitely for absent telemetry.

## TPS plots and publication

Keep `--progress=5 --progress-timestamp` and save full native stdout/stderr.
Parse the native epoch timestamps, not log arrival times. Render a standalone
Matplotlib PNG, **1800 × 600**, one white panel, light horizontal grid, blue
five-second interval bars/steps, five-minute UTC `HH:MM` ticks, and **TPS axis
fixed at 0–10**. State that larger values are clipped. Keep zeros; leave missing
intervals and times outside capture unmeasured, without interpolation or smoothing.

Use the exact per-run `plot-window.json` bounds, matching both Portal charts.
Events: purple UPDATE start/completion, red SIGTERM, green streaming reconnect,
gray first positive bucket end; amber only for an actually observed synchronous
relaxation. Keep line styles/colors consistent. Label approximate times. A bucket
covers its preceding interval and its end is not the exact first transaction time.
Verify zeros and recovery buckets against the raw log; retain raw inputs privately.
Styling or documentation changes require no cloud rerun when native data exist.

Keep these run prefixes under `results/`:
`pgbackrest-repeat-shared-` and `pgbackrest-repeat-wal-`. Each README run section
ends with its three terminal images, two Portal DATA images, and TPS image
immediately beneath the DATA images. Use portable repository-relative image paths,
actual UTC windows, settings/layout, native timing, and cleanup proof. Keep capture
commands, helper installation, and absolute workspace paths out of README.

## Cleanup

Review final images, then immediately run that run's `./cleanup.sh`, independently
of the other run. Verify its unique resource group is absent, including both VMs,
OS/DATA/WAL disks, network resources, and the Blob account/backups. Retain run state
if deletion fails and finish cleanup before abandoning the task. There is no
managed node resource group in this VM recipe. Preserve the watcher baseline;
remove a new regional watcher only with proof this experiment created it and
no remaining run needs it. Stop all temporary browsers, terminals, and deadline
guards after verified deletion. Record cleanup UTC timestamps and keep status
metadata consistent with the completed/failed outcome.
