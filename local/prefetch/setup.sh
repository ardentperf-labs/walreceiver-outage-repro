#!/usr/bin/env bash
set -e

role=$1
PG_BIN="$2/bin"
RUN=$3

# Keep each run's data, sockets, and service names separate.
if [[ $role == primary ]]; then
  mkdir -m 700 "$RUN"
  SOCKET_DIR=$(mktemp -d /tmp/pg-prefetch.XXXXXX)
  PRIMARY_UNIT="pg-prefetch-${SOCKET_DIR##*.}-primary"
  REPLICA_UNIT="pg-prefetch-${SOCKET_DIR##*.}-replica"
  declare -p PG_BIN RUN SOCKET_DIR PRIMARY_UNIT REPLICA_UNIT > "$RUN/repro.env"
  init=("$PG_BIN/initdb" -D "$RUN/primary")
else
  source "$RUN/repro.env"
  init=("$PG_BIN/pg_basebackup" -h "$SOCKET_DIR/primary" -D "$RUN/replica"
        -R -C -S prefetch_replica -c fast)
fi
mkdir "$SOCKET_DIR/$role"

# Initialize or clone inside the cgroup that will run postgres.
sudo systemd-run --unit="pg-prefetch-${SOCKET_DIR##*.}-$role" --uid="$(id -un)" \
  -p MemoryMax=256M -p MemorySwapMax=0 -p IOAccounting=yes \
  /bin/bash -ec '
    bin=$1; data=$2; socket=$3; shift 3
    "$@"
    exec "$bin/postgres" -D "$data" -c listen_addresses= -c "unix_socket_directories=$socket"
  ' bash "$PG_BIN" "$RUN/$role" "$SOCKET_DIR/$role" "${init[@]}"
