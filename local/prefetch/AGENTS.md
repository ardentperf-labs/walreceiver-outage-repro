# Running the local prefetch reproduction

Use README.md's commands as the reproduction. setup.sh only starts a server;
do not replace the manual SQL and counter reads with a repository runner.
The helper returns before startup finishes; wait for pg_isready on each private
socket before initialization or SQL. Invoke it as the normal user with absolute
prefix and run paths. It assumes the documented arguments and cgroup v2.
Keep any agent drivers, parsers, and plotting tools outside
the repository. Validate shell with `bash -n` and compile Python in memory
before launching it. Do not edit a running script.

## Build PostgreSQL

The README assumes the reader already has an installation. For agent runs,
use an existing requested checkout or build it as the normal user. PostgreSQL's
development branch is `master`. From the reproduction repository root:

~~~bash
PG_SOURCE="$HOME/pg-prefetch/postgres"
PG_BUILD="$HOME/pg-prefetch/build"
PG_PREFIX="$HOME/pg-prefetch/pgsql"
REPO_ROOT="$PWD"
mkdir -p "$HOME/pg-prefetch/runs" "$PG_BUILD"
if [[ ! -e "$PG_SOURCE/.git" ]]; then
  git clone --depth 1 https://github.com/postgres/postgres.git "$PG_SOURCE"
fi
cd "$PG_BUILD"
"$PG_SOURCE/configure" --prefix="$PG_PREFIX"
make -j2
make install
cd "$REPO_ROOT"
~~~

After a patch, run `make -C "$PG_BUILD" -j2` and
`make -C "$PG_BUILD" install`. Do not change source revisions between conditions.
Build outside the measured cgroups and record provenance below.

## Before each run

- Build the requested PostgreSQL checkout as the normal user. Save its exact
  commit, `git status --porcelain`, tracked diff, configure options, server
  version, and installed postgres binary SHA-256 outside the repository.
  Rebuild after a patch; do not fetch a different revision between conditions.
- Use fresh run/data directories, private socket directories, and unique
  systemd unit names. Run conditions sequentially on the shared disk. Record
  the backing filesystem/device and `read_ahead_kb`; do not change readahead,
  clear page cache, or tune PostgreSQL settings to obtain an expected ratio.
- Check free space before starting. Preserve old native evidence before
  removing only database copies created by this experiment to recover space.
- Keep PostgreSQL defaults, including autovacuum and asynchronous replication.
  The necessary changes are topology (private sockets, no TCP), memory/swap
  limits, a replication slot, and the explicitly requested condition settings.
  Do not disable autovacuum or enable synchronous standby acknowledgement.

## Four-condition matrix

Run four fresh scale-40 pairs, with 256 MiB per instance:

1. Default recovery prefetch (`try`), default `full_page_writes=on`.
2. Replica `recovery_prefetch=off`, default `full_page_writes=on`.
3. Default recovery prefetch, primary `full_page_writes=off`.
4. Replica `recovery_prefetch=off`, primary `full_page_writes=off`.

Parallelize documentation/review as useful, but keep measured disk workloads
sequential. Cgroup attribution does not eliminate shared-disk contention.

Use README's manual ALTER SYSTEM/reload commands before its preparation
CHECKPOINT. Verify the effective primary and replica settings with SHOW or
pg_settings, including `synchronous_standby_names`, `autovacuum`,
`full_page_writes`, `recovery_prefetch`, `shared_buffers`, `io_method`,
`data_checksums`, and `wal_log_hints`. The on condition uses default `try`;
do not silently substitute `recovery_prefetch=on`.

## Native evidence and measurement

- Save complete initialization/SQL stdout and stderr and native exit codes.
  Retain both server logs from the systemd journal, including shutdown:
  `sudo journalctl --no-pager --utc -u "$PRIMARY_UNIT" > "$RUN/primary.log"`
  and the equivalent command for REPLICA_UNIT. Timestamp CHECKPOINT, UPDATE start and successful
  completion, replay completion, and final checkpoint/flush in UTC.
- Verify `UPDATE 200000`. Do not repeat an uncertain UPDATE in the same pair.
  No background pgbench transactions, receiver signal, or outage is requested.
- Save README's baseline/after systemd counters. Also retain raw `io.stat`
  from both actual service cgroups and reconcile its device totals with the
  systemd counters; the simplified README assumes no stacked devices. Verify `memory.max=268435456` and `memory.swap.max=0`, and save
  before/after memory.stat and memory.events. Any OOM kill invalidates a run.
- Save before/after pg_stat_io, pg_stat_wal, and pg_stat_recovery_prefetch.
  Record the post-checkpoint target LSN and actual replay LSN. Replay catch-up
  establishes the boundary; replication lag is not a success criterion.
- Preparation writes must be flushed before baseline. Final counts include
  UPDATE, replay, and the explicit final checkpoint/write drain. Do not mix
  these counts with the old runner's earlier replay-only window.
- Verify primary `wal_fpi` deltas for FPI-off cases rather than assuming the
  setting eliminates every possible image. Report any residual image count.
- Obtain accounts heap, table, index, and total sizes through PostgreSQL's
  relation-size functions before/after measurement, outside the counter window.

## Results table

The required results table has one primary and one replica row per condition:
prefetch setting, primary FPI setting, instance, read operations, read MB,
and mean read KiB. Use decimal MB and binary KiB.
Retain individual device rows; never double-count stacked/backing devices.
Also report replica/primary read-operation and byte ratios, and the replica
prefetch-default/off comparison for each FPI setting. Explain differing cache
and access patterns; do not tune or cherry-pick runs to reproduce a fixed ratio.

No screenshots or TPS plots are needed for this local UPDATE-only test.
Retain native logs and counters outside the repository as the evidence behind
the results table. Keep published results in README.md; do not add JSON result
files or separate run reports.

## Finish

Stop both servers with `pg_ctl -D ... stop` and verify MainPID is zero and
their cgroups are absent or unpopulated. Save shutdown evidence and logs, then
remove only that run's temporary socket directory. Keep source/build/prefix
trees for patch testing. Never leave a failed or completed test server running.
If setup fails before pg_ctl can find a running server, stop its recorded
systemd unit explicitly and preserve its journal.
Publish verified measurements with the exact source revision, settings,
measurement boundary, and any limitations.
