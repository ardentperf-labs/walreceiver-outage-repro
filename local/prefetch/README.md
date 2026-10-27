# Manual local recovery-prefetch I/O reproduction

Initialize a scale-40 pgbench database and compare one UPDATE on a primary
and physical standby, using an existing PostgreSQL installation. At scale 40,
the initial accounts heap is **537 MB (512 MiB), excluding indexes**. Each service
runs in its own systemd cgroup with 256 MiB memory and no swap. The servers use private
Unix sockets, no TCP listeners, and a physical replication slot. Replication
stays asynchronous; PostgreSQL defaults, including autovacuum, remain enabled.

## Four-condition results

Three runs of each condition, sequentially, at scale 40 on 2026-10-27,
using PostgreSQL 20devel commit
`e5d5d1ad1e3aa495609e19fa716dcea6a39db1bb`, on one ext4 disk with
8 MiB readahead. Counts include DATA + WAL during UPDATE, replay, and final
checkpoints. MB is decimal; KiB is binary.

The statement updates 200,000 of the 4,000,000 accounts:

~~~sql
UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid % 20 = 0;
~~~

These ran on my laptop, a Dell XPS 14 with an NVMe SSD. Each numeric cell
lists **run1 / run2 / run3**.

| Replica prefetch | Primary FPIs | Instance | Read ops | Read MB | Mean read KiB |
| --- | --- | --- | ---: | ---: | ---: |
| Default (`try`) | on | Primary | 5,835 / 3,797 / 4,846 | 1,929.05 / 1,795.45 / 1,556.14 | 322.9 / 461.8 / 313.6 |
| Default (`try`) | on | Replica | 71,617 / 75,289 / 75,686 | 600.49 / 857.91 / 662.05 | 8.2 / 11.1 / 8.5 |
| `off` | on | Primary | 4,626 / 2,992 / 11,768 | 2,221.05 / 1,815.11 / 1,764.84 | 468.9 / 592.4 / 146.5 |
| `off` | on | Replica | 104 / 417 / 53 | 12.17 / 108.38 / 2.26 | 114.3 / 253.8 / 41.6 |
| Default (`try`) | off | Primary | 7,435 / 5,781 / 3,294 | 1,008.17 / 911.67 / 864.67 | 132.4 / 154.0 / 256.3 |
| Default (`try`) | off | Replica | 29,524 / 52,955 / 29,008 | 677.05 / 745.05 / 737.94 | 22.4 / 13.7 / 24.8 |
| `off` | off | Primary | 7,445 / 1,954 / 2,988 | 1,072.37 / 827.97 / 787.54 | 140.7 / 413.8 / 257.4 |
| `off` | off | Replica | 380 / 1,664 / 901 | 769.84 / 949.42 / 781.42 | 1,978.4 / 557.2 / 847.0 |

With default prefetch, replica/primary read-operation ratios were
**12.27× / 19.83× / 15.62×** with FPIs on and **3.97× / 9.16× / 8.81×**
with FPIs off. Comparing FPI-off replicas, prefetch increased read operations
**77.7× / 31.8× / 32.2×** with similar MB: many small reads versus few large
reads, consistent with Linux readahead/request combining.

The primary scans and updates the table; the replica replays WAL. FPIs supply
page contents, changing replay's read requirements. Ratios vary across runs;
the counters establish request sizes and counts, not the mechanism behind them.

Run each of the four prefetch/FPI combinations above with a fresh pair and
the same binary, sequentially.

## Setup

Requires Linux with systemd/cgroup v2, sudo, and a local disk-backed filesystem.
Point `PG_PREFIX` at your PostgreSQL prefix (containing `bin/`, `lib/`, and
`share/`). Use the same binary and fresh data directories for all four conditions.
Run the helper as your normal user, with absolute paths for `PG_PREFIX` and `RUN`.

~~~bash
PG_PREFIX="$HOME/pg-prefetch/pgsql"
export PATH="$PG_PREFIX/bin:$PATH" PGDATABASE=postgres
mkdir -p "$HOME/pg-prefetch/runs"
~~~

## One fresh condition

Choose a new RUN path for each condition. The helper only initializes and
starts servers. The primary invocation creates `$RUN/repro.env`, which records
the binary path, run directory, private socket directory, and systemd unit names.
Source it to make those variables available in your shell; the replica invocation
reads the same file. Initialize pgbench manually before cloning the replica.

~~~bash
RUN="$HOME/pg-prefetch/runs/default-fpi-on"
local/prefetch/setup.sh primary "$PG_PREFIX" "$RUN"
source "$RUN/repro.env"
pg_isready -h "$SOCKET_DIR/primary"
# Repeat until accepting connections, then initialize:
pgbench -i -s 40 -h "$SOCKET_DIR/primary"
local/prefetch/setup.sh replica "$PG_PREFIX" "$RUN"
pg_isready -h "$SOCKET_DIR/replica"
# Repeat until accepting connections before continuing.
~~~

After cloning, apply only the overrides for this condition, before the
preparation checkpoint. Skip the commands for default settings:

~~~bash
# For either FPI-off condition, run on the primary:
psql -X -h "$SOCKET_DIR/primary" -v ON_ERROR_STOP=1 -c 'ALTER SYSTEM SET full_page_writes = off'
psql -X -h "$SOCKET_DIR/primary" -v ON_ERROR_STOP=1 -c 'SELECT pg_reload_conf()'

# For either prefetch-off condition, run on the replica:
psql -X -h "$SOCKET_DIR/replica" -v ON_ERROR_STOP=1 -c 'ALTER SYSTEM SET recovery_prefetch = off'
psql -X -h "$SOCKET_DIR/replica" -v ON_ERROR_STOP=1 -c 'SELECT pg_reload_conf()'
~~~

## Measure

Prepare the primary, save its flushed WAL LSN, and repeat the replica query
until replay reaches that target. Then checkpoint the replica and sync its
PG_VERSION file.

~~~bash
psql -X -h "$SOCKET_DIR/primary" -c CHECKPOINT
TARGET_LSN=$(psql -X -h "$SOCKET_DIR/primary" -Atc 'SELECT pg_current_wal_flush_lsn()')
printf 'Preparation target: %s\n' "$TARGET_LSN"
psql -X -h "$SOCKET_DIR/replica" -Atc \
  "SELECT pg_last_wal_replay_lsn() >= '$TARGET_LSN'::pg_lsn, pg_last_wal_replay_lsn()"
# Repeat the replica query until its first column is t.
psql -X -h "$SOCKET_DIR/replica" -c CHECKPOINT
sync -f "$RUN/replica/PG_VERSION"
~~~

Save systemd's cumulative read counters for both services:

~~~bash
systemctl show "$PRIMARY_UNIT" "$REPLICA_UNIT" \
  -p Id -p IOReadOperations -p IOReadBytes | tee "$RUN/io.before"
~~~

Run the UPDATE once; it should report UPDATE 200000. Do not retry if the
commit outcome is uncertain.

~~~bash
psql -X -h "$SOCKET_DIR/primary" -v ON_ERROR_STOP=1 -c \
  'UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid % 20 = 0'
~~~

Checkpoint the primary, save the new flushed WAL LSN, and repeat the replica
query until replay reaches it. Then checkpoint the replica, sync PG_VERSION,
wait two seconds, and save the after counters. This window includes the UPDATE,
replay, and final write drain.

~~~bash
psql -X -h "$SOCKET_DIR/primary" -c CHECKPOINT
TARGET_LSN=$(psql -X -h "$SOCKET_DIR/primary" -Atc 'SELECT pg_current_wal_flush_lsn()')
printf 'Final target: %s\n' "$TARGET_LSN"
psql -X -h "$SOCKET_DIR/replica" -Atc \
  "SELECT pg_last_wal_replay_lsn() >= '$TARGET_LSN'::pg_lsn, pg_last_wal_replay_lsn()"
# Repeat the replica query until its first column is t.
psql -X -h "$SOCKET_DIR/replica" -c CHECKPOINT
sync -f "$RUN/replica/PG_VERSION"
sleep 2
systemctl show "$PRIMARY_UNIT" "$REPLICA_UNIT" \
  -p Id -p IOReadOperations -p IOReadBytes | tee "$RUN/io.after"
~~~

For each service, subtract its `io.before` counters from its `io.after`
counters:

- **Read ops** = change in `IOReadOperations`.
- **Read MB** = change in `IOReadBytes` / 1,000,000.
- **Mean read KiB** = change in `IOReadBytes` / read ops / 1,024
  (undefined if read ops is zero).

Systemd reports totals across devices. This recipe assumes a single backing
disk without stacked devices; use per-device `io.stat` for stacked storage to
avoid double-counting.

These are whole-instance **DATA + WAL** block operations and bytes, rather
than PostgreSQL read calls or physical media accesses beneath the host disk.
Cache residency and request combining affect the ratios; no fixed factor or
replication lag is required.

For each service, copy its before/after values into these variables and
calculate the results. Skip the last command if `read_ops` is zero.

~~~bash
ops_before=...
ops_after=...
bytes_before=...
bytes_after=...

read_ops=$((ops_after - ops_before))
read_bytes=$((bytes_after - bytes_before))

echo "Read operations: $read_ops"
awk "BEGIN {printf \"Read MB: %.2f\\n\", $read_bytes / 1000000}"
awk "BEGIN {printf \"Mean read KiB: %.1f\\n\", $read_bytes / $read_ops / 1024}"
~~~

## Stop

Stop both services after each run. Verify their MainPID values are zero and
their cgroups are absent or unpopulated. Remove only the run's temporary socket
directory; keep its database copies.

~~~bash
pg_ctl -D "$RUN/replica" stop
pg_ctl -D "$RUN/primary" stop
sudo systemctl show -p MainPID "$PRIMARY_UNIT" "$REPLICA_UNIT"
rmdir "$SOCKET_DIR/primary" "$SOCKET_DIR/replica" "$SOCKET_DIR"
~~~
