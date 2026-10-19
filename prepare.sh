#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source .repro.env
# G generates unfrozen rows on the server; p creates the standard primary keys.
kubectl exec postgres-1 -c postgres -- pgbench --username=postgres \
  --initialize --scale=640 --init-steps=dtGp postgres
kubectl exec postgres-1 -c postgres -- psql -X -U postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_size_pretty(pg_relation_size('pgbench_accounts')) AS heap_size"
while true; do
  lag_bytes=$(kubectl exec postgres-1 -c postgres -- psql -X -U postgres -Atc \
    'SELECT pg_current_wal_lsn() - replay_lsn FROM pg_stat_replication')
  echo "Waiting for replay lag to reach zero: $((lag_bytes / 1024 / 1024)) MB ($lag_bytes bytes)"
  [[ $lag_bytes == 0 ]] && break
  sleep 5
done
