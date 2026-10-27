#!/usr/bin/env bash
# Invoked by provision.sh as root over SSH; no cloud resources are created here.
set -euo pipefail
role=$1
primary_ip=$2
replica_ip=$3
disk_layout=${4:-}
: "${REPLICATION_PASSWORD:?Replication password must be supplied by provision.sh}"
: "${STORAGE_ACCOUNT:?Storage account must be supplied by provision.sh}"
: "${STORAGE_KEY:?Storage key must be supplied by provision.sh}"
[[ $role == primary || $role == replica ]] || exit 2
[[ $disk_layout == shared || $disk_layout == dedicated ]] || {
  echo 'Disk layout must be shared or dedicated.' >&2
  exit 2
}
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait

# Select unique, unmounted, unpartitioned disks before formatting any of them.
# In the dedicated layout, distinct sizes keep DATA and WAL roles unambiguous,
# even when Azure exposes managed disks through NVMe device names.
disk_inventory=$(lsblk --json --bytes --paths --output NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS)
selected_disks=$(DISK_INVENTORY="$disk_inventory" DISK_LAYOUT="$disk_layout" python3 -c '
import json, os, sys
devices = json.loads(os.environ["DISK_INVENTORY"])["blockdevices"]
layout = os.environ["DISK_LAYOUT"]
def has_mount(d):
    return any(d.get("mountpoints") or []) or any(has_mount(c) for c in d.get("children", []))
expected = [(64, "DATA")]
if layout == "dedicated":
    expected.append((32, "WAL"))
for size, label in expected:
    matches = [d["name"] for d in devices
               if d["type"] == "disk" and d["size"] == size * 1024**3
               and not d.get("fstype") and not d.get("children") and not has_mount(d)]
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one unmounted, unpartitioned {size}-GiB {label} disk")
    print(matches[0])')
mapfile -t selected_disks <<< "$selected_disks"
expected_disk_count=1
if [[ $disk_layout == dedicated ]]; then expected_disk_count=2; fi
[[ ${#selected_disks[@]} == $expected_disk_count ]] || {
  echo "Failed to identify the expected $disk_layout layout disks." >&2
  exit 1
}
data_disk=${selected_disks[0]}
disks_to_format=("$data_disk")
if [[ $disk_layout == dedicated ]]; then
  wal_disk=${selected_disks[1]}
  disks_to_format+=("$wal_disk")
fi
for disk in "${disks_to_format[@]}"; do
  if blkid -p "$disk" >/dev/null 2>&1; then
    echo "Refusing to format $disk because it already contains a recognized signature." >&2
    exit 1
  fi
done
mkfs.ext4 -q "$data_disk"
install -d -o root -g root -m 0755 /var/lib/postgresql
data_uuid=$(blkid -s UUID -o value "$data_disk")
printf 'UUID=%s /var/lib/postgresql ext4 defaults 0 2\n' "$data_uuid" >> /etc/fstab
mount /var/lib/postgresql
if [[ $disk_layout == dedicated ]]; then
  mkfs.ext4 -q "$wal_disk"
  install -d -o root -g root -m 0755 /var/lib/postgresql-wal
  wal_uuid=$(blkid -s UUID -o value "$wal_disk")
  printf 'UUID=%s /var/lib/postgresql-wal ext4 defaults 0 2\n' "$wal_uuid" >> /etc/fstab
  mount /var/lib/postgresql-wal
  data_device=$(findmnt -n -o MAJ:MIN --target /var/lib/postgresql)
  wal_device=$(findmnt -n -o MAJ:MIN --target /var/lib/postgresql-wal)
  [[ -n $data_device && -n $wal_device && $data_device != "$wal_device" ]] || {
    echo 'DATA and WAL disks did not mount as different devices.' >&2
    exit 1
  }
fi

apt-get update
apt-get install -y curl ca-certificates postgresql-common
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
apt-get update
apt-get install -y postgresql-18 postgresql-client-18 pgbackrest patroni python3-etcd
python3 -c 'import etcd; from patroni.dcs import etcd3' >/dev/null

if [[ $role == primary ]]; then
  apt-get install -y etcd-server etcd-client
  # Keep the one-member DCS on the OS disk and bind only loopback and the
  # primary's private NIC. Its peer port is loopback-only in this topology.
  cat > /etc/default/etcd <<EOF
ETCD_NAME="default"
ETCD_DATA_DIR="/var/lib/etcd/default"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://$primary_ip:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://$primary_ip:2379"
ETCD_LISTEN_PEER_URLS="http://127.0.0.1:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://127.0.0.1:2380"
ETCD_INITIAL_CLUSTER="default=http://127.0.0.1:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
  install -d -o etcd -g etcd -m 0750 /var/lib/etcd/default
  systemctl enable etcd.service
  systemctl restart etcd.service
  deadline=$((SECONDS + 120))
  until ETCDCTL_API=3 etcdctl --endpoints="http://$primary_ip:2379" endpoint health >/dev/null 2>&1; do
    (( SECONDS < deadline )) || { echo 'Timed out waiting for the private etcd endpoint.' >&2; exit 1; }
    sleep 2
  done
fi

# Azure credentials and pgBackRest configuration stay on the OS disk.
install -d -o postgres -g postgres -m 0750 /etc/pgbackrest /var/log/pgbackrest
install -o postgres -g postgres -m 0600 /dev/null /etc/pgbackrest/pgbackrest.conf
cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-type=azure
repo1-azure-account=$STORAGE_ACCOUNT
repo1-azure-container=backups
repo1-azure-key=$STORAGE_KEY
repo1-path=/repro
repo1-retention-full=1

[repro]
pg1-path=/var/lib/postgresql/18/main
EOF
unset STORAGE_KEY

# PostgreSQL's package-created cluster is empty at this point. Remove that
# competing unit and let Patroni initialize directly in PGDG's DATA path.
systemctl disable postgresql.service postgresql@18-main.service >/dev/null 2>&1 || true
pg_dropcluster --stop 18 main
install -d -o postgres -g postgres -m 0755 /var/lib/postgresql/18
if [[ $disk_layout == dedicated ]]; then
  install -d -o postgres -g postgres -m 0700 /var/lib/postgresql-wal/18/main
fi

# Patroni is the only PostgreSQL manager. Its child postmaster inherits these
# descriptors, preserving native PostgreSQL output on the OS disk without
# changing PostgreSQL's logging GUCs.
install -d -o postgres -g postgres -m 0750 /var/log/postgresql
install -o postgres -g postgres -m 0640 /dev/null /var/log/postgresql/postgresql-18-main.log
install -d -o root -g root -m 0755 /etc/systemd/system/patroni.service.d
cat > /etc/systemd/system/patroni.service.d/10-repro-logs.conf <<'EOF'
[Service]
StandardOutput=append:/var/log/postgresql/postgresql-18-main.log
StandardError=append:/var/log/postgresql/postgresql-18-main.log
EOF
systemctl daemon-reload

install -d -o postgres -g postgres -m 0750 /etc/patroni
patroni_ip=$primary_ip
if [[ $role == replica ]]; then patroni_ip=$replica_ip; fi
initdb_waldir_yaml=
basebackup_waldir_yaml=
if [[ $disk_layout == dedicated ]]; then
  initdb_waldir_yaml='    - waldir: /var/lib/postgresql-wal/18/main'
  basebackup_waldir_yaml=$'  basebackup:\n    - waldir: /var/lib/postgresql-wal/18/main'
fi
cat > /etc/patroni/config.yml <<EOF
scope: pgbackrest-repro
namespace: /service/
name: $role

restapi:
  listen: $patroni_ip:8008
  connect_address: $patroni_ip:8008
  allowlist:
    - 127.0.0.1/32
    - $primary_ip/32
    - $replica_ip/32

etcd3:
  hosts: $primary_ip:2379

bootstrap:
  dcs:
    synchronous_mode: true
    synchronous_mode_strict: true
    postgresql:
      use_slots: true
  initdb:
    - auth-local: peer
    - auth-host: scram-sha-256
${initdb_waldir_yaml}

postgresql:
  listen: $patroni_ip:5432
  connect_address: $patroni_ip:5432
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin
${basebackup_waldir_yaml}
  use_unix_socket: true
  pgpass: /etc/patroni/pgpass
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
      password: $REPLICATION_PASSWORD
  pg_hba:
    - local all postgres peer
    - local all all peer
    - host all all 127.0.0.1/32 scram-sha-256
    - host all all ::1/128 scram-sha-256
    - host replication replicator $primary_ip/32 scram-sha-256
    - host replication replicator $replica_ip/32 scram-sha-256
  parameters:
    archive_mode: 'on'
    archive_command: 'pgbackrest --stanza=repro archive-push "%p"'
EOF
if [[ $role == replica ]]; then
  cat >> /etc/patroni/config.yml <<'EOF'
  recovery_conf:
    restore_command: 'pgbackrest --stanza=repro archive-get "%f" "%p"'
EOF
fi
chown postgres:postgres /etc/patroni/config.yml
chmod 0600 /etc/patroni/config.yml
patroni --validate-config /etc/patroni/config.yml

systemctl enable --now patroni.service
deadline=$((SECONDS + 240))
endpoint=primary
if [[ $role == replica ]]; then endpoint=replica; fi
until curl --fail --silent --max-time 3 "http://$patroni_ip:8008/$endpoint" >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { echo "Timed out waiting for Patroni /$endpoint on $patroni_ip." >&2; exit 1; }
  sleep 2
done
if [[ $disk_layout == dedicated ]]; then
  mountpoint -q /var/lib/postgresql-wal
  expected_wal_dir=$(readlink -e /var/lib/postgresql-wal/18/main)
  actual_wal_dir=$(readlink -e /var/lib/postgresql/18/main/pg_wal)
  [[ $actual_wal_dir == "$expected_wal_dir" ]] || {
    echo "PostgreSQL pg_wal is not on the dedicated WAL disk: $actual_wal_dir" >&2
    exit 1
  }
fi
runuser -u postgres -- psql -XAtc 'SELECT version()'
