# Collecting screenshots

Keep screenshot tooling temporary, outside the repository. Document the
reproduction in README.md; put capture instructions only in this file.
Do not provision Azure resources merely to edit documentation.

For the main test, collect five real screenshots and one TPS plot:

| File | Contents |
| --- | --- |
| `results/terminal2-healthy.png` | Terminal 2 before the disconnect, while pgbench completes writes |
| `results/terminal2-unhealthy.png` | The same terminal after disconnect, with prolonged replication waits |
| `results/terminal2-reconnected.png` | Wait events after streaming reconnects, captioned with the approximate reconnect time in UTC |
| `results/primary-data-iops.png` | Primary DATA disk read/write IOPS in Azure Portal |
| `results/replica-data-iops.png` | Replica DATA disk read/write IOPS in Azure Portal |
| `results/tps.png` | Timestamped pgbench TPS aligned with the Azure charts |

## Actual terminal captures

Run README's Terminal 2 command in a real terminal and capture its viewport.
Do not recreate its table from saved text or invent healthy/unhealthy rows.

A browser terminal such as `ttyd` works with Playwright screenshots:

1. Put the exact observer command in a temporary shell script. Source
   `.repro.env` from the project directory before running it.
2. Start a read-only terminal bound to loopback, for example:

   ```bash
   ttyd --interface 127.0.0.1 --port 7681 --check-origin \
     -t fontSize=20 -t screenReaderMode=true bash /tmp/observer.sh
   ```

3. Open `http://127.0.0.1:7681` with Playwright. A 1500 × 650 viewport worked
   well; ensure the column headings, all ten sessions, and watch timestamp are
   visible. If installing ttyd starts a system service, stop that service and
   use only the temporary loopback listener.
4. Save the healthy screenshot **before sending SIGTERM**. Coordinate with the
   test runner so it waits for this capture. pgbench must still complete writes;
   brief `SyncRep` waits are normal and need not be absent.
5. After the single walreceiver SIGTERM, wait for repeated zero-TPS progress
   lines and increasing wait ages, then capture the same live terminal again.
   Around 30 seconds makes the difference clear. Record actual waits: some
   sessions can queue on row locks rather than `SyncRep`.

6. In every test with a disconnect, record the approximate UTC time when WAL
   streaming reconnects, using PostgreSQL logs or the first observed streaming
   status. After reconnect, capture Terminal 2 again while pgbench is running.
   Put the **approximate reconnect time** above this image in the README; the
   watch timestamp shows capture time and must not be used as the reconnect time.
   For preferred durability, writes can resume before streaming reconnects, so
   resumed TPS alone is not evidence of reconnect. For the no-disconnect control,
   capture final waits instead and label it as having no disconnect.

Stop the temporary terminal server after all terminal captures. Keep its installation
and capture commands out of README and the reproduction scripts.

## Azure Portal DATA disk charts

Use Playwright to capture Azure Portal itself. Do not substitute locally plotted
metrics. Capture only the two DATA disks; WAL disk charts are not needed.

Identify the current disks rather than reusing an earlier run's resource IDs:

```bash
source .repro.env
kubectl get pods -l cnpg.io/cluster=postgres -o wide --show-labels
kubectl get pv -o custom-columns=CLAIM:.spec.claimRef.name,DISK:.spec.csi.volumeHandle
```

Match the current primary and replica to their DATA PVCs (`postgres-1` and
`postgres-2` on a fresh cluster). The `-wal` PVCs are separate disks.

### Chart configuration and capture

For each DATA disk, open **Monitoring → Metrics** and configure:

- Namespace: **Disk standard metrics**.
- Metrics: **Disk Read Operations/sec(Preview)** and
  **Disk Write Operations/sec(Preview)**, both using **Average**.
- Chart type: **Stacked area**, with read and write IOPS stacked rather than
  drawn as lines. In Portal versions that label this **Area chart**, select that
  option and verify the series are stacked.
- Click the **time-range button in the top-right corner**. In that panel, open
  the **Time granularity** dropdown, change **Automatic** to **1 minute**, and
  click **Apply**.
- The **same custom UTC time range** for both charts: begin before pgbench
  starts and end after the replica catches up and TPS resumes. Include the
  complete test, not just the beginning of the outage.
- Titles identifying **Primary DATA** or **Replica DATA**, read/write IOPS,
  and one-minute averages.

Set the browser timezone to UTC as well as the Portal time picker. Check the
axis says UTC+00:00; the picker can still label this “Local Time.”

Portal metric controls may be inside an iframe. Locate the frame containing
the expected disk resource name and **Add metric** button, then interact there.
Wait for the actual curves and numeric legend values to load. A blank chart
with default axes is not a finished capture. Recent data can take several
minutes to arrive; refresh after recovery before saving the final images.

Before taking the screenshot, reopen the time-range panel and confirm that
**Time granularity** is still **1 minute**, then close the panel and let the chart
finish refreshing. Keep the full granularity label visible in the screenshot
(use a tooltip if needed). Setting the chart title to “1-minute averages” does
not change the dropdown setting.

A 1800 × 1100 browser viewport worked well. Capture the chart, title, time
range, axes, and legend. Exclude the account header using screenshot clipping
if needed; leave metric data intact. Open both saved PNGs and verify their disk
identities, full time ranges, one-minute setting, stacked areas, and visible data.

## Timestamped TPS capture and plot

Do this for **every run**, including the control and all test conditions. Keep the capture and plotting
scripts temporary; do not add a metrics framework or alter the workload.

### Capture

- Add `--progress-timestamp` to the existing pgbench `--progress=5` command.
  [PostgreSQL documents this option](https://www.postgresql.org/docs/18/pgbench.html)
  as replacing elapsed seconds with Unix-epoch timestamps at millisecond
  precision. Use these timestamps, not the time a log line arrives through
  `kubectl exec`.
- Capture the complete native stdout and stderr, including progress, failures,
  errors, and any final summary. Progress is written to stderr. Keep progress
  visible in the live terminal as well as saving it. If running remotely, save
  a copy inside the pod so an interrupted exec connection does not lose data,
  and copy it out **before cleanup**.
- Check the pgbench pod's UTC clock against the clock used for event timestamps.
  Record approximate UTC times for VACUUM start and completion, disconnect,
  streaming reconnect, and resumed TPS. For preferred durability, also record
  when synchronous replication is relaxed. Keep these events distinct.
- Collect baseline, VACUUM, any outage, and recovery through healthy progress
  after actual streaming reconnect. Keep offered load running throughout this
  window. A no-disconnect control must cover VACUUM and subsequent catch-up.

### Plot

- Use a standard plotting tool such as Matplotlib to produce a standalone PNG
  from the native timestamp/TPS pairs. Save the main plot as `results/tps.png`
  and comparison plots as `conditions/<condition>-tps.png`, using the same condition
  prefixes as their other images.
- Use a consistent **1800 × 600 pixel** canvas, margins, and font sizes for
  every run. Use one chart panel, a white background, light horizontal grid,
  blue five-second interval bars or step marks, and five-minute UTC clock ticks
  labeled `HH:MM`. Give each plot one concise condition title and a date and
  chart-window caption.
- Convert epoch timestamps to UTC and label the horizontal axis with UTC clock
  times. Use the exact start and end in that run's `plot-window.json`, matching
  both Azure IOPS charts. Label the vertical axis **TPS**. Preserve the native
  five-second resolution; Azure's one-minute granularity does not require
  averaging away short stalls in the TPS plot.
- Treat each progress value as completed transactions per second during the
  preceding reporting interval, not an instantaneous rate. Keep reported zeros.
  Leave missing intervals as gaps; do not interpolate, smooth, or fill them with
  zeros. Leave the area before the first observation and after capture ends
  unmeasured even if the common chart window extends beyond the log.
- Use exactly one chart panel in **every** run, with the TPS axis fixed at
  0–10. Values above 10 TPS are clipped; state this clearly in the plot.
- Use the same semantic event colors in every plot: purple for VACUUM start and
  completion, red for walreceiver SIGTERM, amber for synchronous replication
  relaxed, green for streaming reconnected, and gray for a first positive TPS
  bucket end. Keep each event's color and line style consistent, identify the
  events in a clear legend, and label approximate times as approximate. A first
  positive bucket marker denotes the reporting-interval end, not the exact time
  of the first completed transaction. Do not invent disconnect or reconnect
  markers for a no-disconnect run.
- Verify plotted zero-TPS intervals and the first positive recovery bucket
  against the raw log. A reporting bucket does not establish the exact first
  completed transaction time. Retain the raw log and plotting input privately.
  For an older log containing only elapsed times, require a verified client
  start-time anchor and disclose its uncertainty; do not manufacture exact UTC
  timestamps or align the series by eye.
- When publishing a run's results, put its TPS graph **immediately beneath the
  two Azure DATA disk IOPS graphs** in that run's README section. Use a relative
  image path and the same chart-window caption. Keep capture and plotting
  instructions out of README. Generate the plot after cloud cleanup if useful;
  save its source log first so plotting does not extend Azure runtime.
- If retained native logs, event metadata, and the chart window are accurate,
  changing plot style only requires regenerating the PNGs; it does not require
  rerunning the reproduction or accessing Azure.

## Preferred-durability condition captures

For the two preferred-durability conditions in `conditions/README.md`, save six screenshots:
the initial waits, waits about **15 seconds after disconnect**, waits about
**one minute after that first post-disconnect capture** (about 75 seconds after
disconnect), waits after actual streaming reconnect, and the two DATA IOPS charts. Preserve the actual watch timestamps
in both post-disconnect screenshots and fill their README timestamp captions.
Capture at these times even if the waits differ from the expected behavior;
do not delay a capture waiting for every session to enter or leave `SyncRep`.
Use native pgbench progress to confirm whether transactions are flowing again.
Save results under the condition-specific filenames in the conditions README and
replace expectations with actual observations after testing. These conditions
are independent fresh runs; do not carry `recovery_prefetch=off` over from the
prefetch-off condition. Leave `wal_sender_timeout` at its CNPG default in both conditions
and leave `maximumLag` and probe timing fields unset in the streaming condition.
Also produce the timestamped TPS plot described above for each condition.

## Finish and clean up

Keep the requested images at the end of each README section using
repository-relative image paths (six including TPS for the main test and the
no-disconnect and prefetch-off conditions, seven for each preferred-durability condition).
Update the chart time-window caption for the actual run. Do not add capture
machinery, absolute workspace paths, or extra image-download links to README.
T3's inline README preview may fail to embed an image that opens directly;
retain portable paths for GitHub.

Capture and verify the Portal images **before** deleting the cluster. Then run
`./cleanup.sh` and verify the experiment resource group and managed node group
are absent. This removes the nodes, disks, and Blob account. Record existing
Network Watchers before provisioning; remove an automatically created regional
watcher only if this experiment created it. Preserve pre-existing resources.
Never leave a test cluster running after screenshot collection or a failed run.
