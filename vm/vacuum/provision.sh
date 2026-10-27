#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ ! -e .repro.env && ! -e .repro-ssh ]] || { echo 'Run ./cleanup.sh before provisioning again.' >&2; exit 1; }
for command in az ssh ssh-keygen curl python3 openssl timeout; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
LOCATION=${LOCATION:-eastus}
VM_SIZE=Standard_D2s_v6
ADMIN_USER=pgadmin
DISK_LAYOUT=${DISK_LAYOUT:-dedicated}
PREFLIGHT_EVIDENCE=${PREFLIGHT_EVIDENCE:-}
[[ $DISK_LAYOUT == shared || $DISK_LAYOUT == dedicated ]] || {
  echo 'DISK_LAYOUT must be shared or dedicated.' >&2
  exit 1
}
if [[ -n $PREFLIGHT_EVIDENCE ]]; then
  [[ -r $PREFLIGHT_EVIDENCE ]] || { echo 'PREFLIGHT_EVIDENCE must name a readable JSON file.' >&2; exit 1; }
  PREFLIGHT_EVIDENCE=$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$PREFLIGHT_EVIDENCE")
fi
SSH_SOURCE_CIDR=${SSH_SOURCE_CIDR:-$(curl --fail --silent --show-error --max-time 20 https://api.ipify.org)/32}
python3 - "$SSH_SOURCE_CIDR" <<'PY'
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
if network.version != 4 or network.prefixlen == 0:
    raise SystemExit('SSH_SOURCE_CIDR must be a restricted IPv4 CIDR')
PY
if [[ -n $PREFLIGHT_EVIDENCE ]]; then
  PREFLIGHT_JSON=$(cat -- "$PREFLIGHT_EVIDENCE") python3 - "$LOCATION" "$VM_SIZE" <<'PY'
import datetime as dt
import json
import os
import sys

evidence = json.loads(os.environ['PREFLIGHT_JSON'])
location, size = sys.argv[1:]
if evidence.get('location', '').lower() != location.lower():
    raise SystemExit('Preflight evidence location does not match this run.')
if evidence.get('size') != size:
    raise SystemExit('Preflight evidence VM size does not match this run.')
if int(evidence.get('reserved_vcpus', 0)) < 8:
    raise SystemExit('Preflight evidence must reserve at least eight vCPUs for both runs.')
checked_at = dt.datetime.fromisoformat(evidence['checked_at'].replace('Z', '+00:00'))
if checked_at.tzinfo is None:
    raise SystemExit('Preflight checked_at must include a UTC offset.')
age = (dt.datetime.now(dt.timezone.utc) - checked_at.astimezone(dt.timezone.utc)).total_seconds()
if age < 0 or age > 1800:
    raise SystemExit('Preflight evidence must be no more than 30 minutes old.')
if int(evidence.get('cores_available', 0)) < 8:
    raise SystemExit('Preflight evidence does not show eight available total vCPUs.')
if int(evidence.get('dsv6_available', 0)) < 8:
    raise SystemExit('Preflight evidence does not show eight available StandardDsv6Family vCPUs.')
if evidence.get('sku_location_allowed') is not True:
    raise SystemExit('Preflight evidence does not confirm regional SKU availability.')
PY
else
  # Check the requested generation once; zonal restrictions do not block this run.
  usage=$(az vm list-usage --location "$LOCATION" -o json)
  skus=$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --all -o json)
  USAGE_JSON="$usage" SKU_JSON="$skus" python3 - "$VM_SIZE" <<'PY'
import json, os, sys
usage = json.loads(os.environ['USAGE_JSON'])
for family in ('cores', 'standardDSv6Family'):
    entries = [x for x in usage if x['name']['value'].lower() == family.lower()]
    if not entries or int(entries[0]['limit']) - int(entries[0]['currentValue']) < 4:
        raise SystemExit(f'Insufficient quota for four vCPUs: {family}')
skus = [x for x in json.loads(os.environ['SKU_JSON']) if x['name'] == sys.argv[1]]
if not skus or any(r.get('type', '').lower() == 'location' for x in skus for r in x.get('restrictions', [])):
    raise SystemExit('VM SKU unavailable for regional deployment')
PY
fi
echo 'Existing reproduction groups (coordinate concurrent runs before proceeding):'
az group list --query "[?starts_with(name, 'rg-walreceiver-')].{name:name,location:location}" -o table
# shellcheck disable=SC2034 # Serialized by save_state.
WATCHER_BASELINE=$(az network watcher list --query '[].id' -o tsv)
RG="rg-walreceiver-$(date -u +%Y%m%d-%H%M%S)-$RANDOM"
STORAGE_ACCOUNT="walrepro$(openssl rand -hex 8)"
PRIMARY_PRIVATE_IP=10.42.0.4
REPLICA_PRIVATE_IP=10.42.0.5
umask 077
save_state() {
  local variable
  for variable in RG LOCATION VM_SIZE ADMIN_USER DISK_LAYOUT PREFLIGHT_EVIDENCE SSH_SOURCE_CIDR PRIMARY_PRIVATE_IP REPLICA_PRIVATE_IP PRIMARY_IP REPLICA_IP WATCHER_BASELINE STORAGE_ACCOUNT; do
    printf '%s=%q\n' "$variable" "${!variable-}"
  done > .repro.env
}
save_state
on_exit() {
  local exit_status=$?
  trap - EXIT
  if (( exit_status != 0 )); then
    ./cleanup.sh || echo 'Cleanup incomplete; retained .repro.env. Retry ./cleanup.sh.' >&2
  fi
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir .repro-ssh
ssh-keygen -q -t ed25519 -N '' -f .repro-ssh/id_ed25519
az group create --name "$RG" --location "$LOCATION" -o none
az storage account create -g "$RG" -n "$STORAGE_ACCOUNT" -l "$LOCATION" \
  --kind StorageV2 --sku Standard_LRS --min-tls-version TLS1_2 \
  --allow-blob-public-access false -o none
STORAGE_KEY=$(az storage account keys list -g "$RG" -n "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)
[[ -n $STORAGE_KEY ]] || { echo 'Storage account key missing.' >&2; exit 1; }
AZURE_STORAGE_KEY="$STORAGE_KEY" az storage container create --account-name "$STORAGE_ACCOUNT" \
  --auth-mode key --name backups --public-access off -o none
az network nsg create -g "$RG" -n repro-nsg -l "$LOCATION" -o none
az network nsg rule create -g "$RG" --nsg-name repro-nsg -n SSH --priority 1000 \
  --source-address-prefixes "$SSH_SOURCE_CIDR" --destination-port-ranges 22 --protocol Tcp --access Allow -o none
az network vnet create -g "$RG" -n repro-vnet -l "$LOCATION" \
  --address-prefixes 10.42.0.0/16 --subnet-name postgres --subnet-prefixes 10.42.0.0/24 -o none
for role in primary replica; do
  private_variable="${role^^}_PRIVATE_IP"
  # The shared layout has one 64-GiB DATA/WAL disk. The dedicated layout adds
  # a separate 32-GiB WAL disk; both layouts leave Azure disk caching disabled.
  if [[ $DISK_LAYOUT == dedicated ]]; then data_disk_sizes=(64 32); else data_disk_sizes=(64); fi
  az vm create -g "$RG" -n "$role" -l "$LOCATION" --size "$VM_SIZE" \
    --image Ubuntu2404 --admin-username "$ADMIN_USER" --ssh-key-values .repro-ssh/id_ed25519.pub \
    --vnet-name repro-vnet --subnet postgres --private-ip-address "${!private_variable}" \
    --nsg repro-nsg --nsg-rule NONE --public-ip-sku Standard \
    --storage-sku Standard_LRS --os-disk-size-gb 30 --data-disk-sizes-gb "${data_disk_sizes[@]}" \
    --data-disk-caching None --no-wait -o none
done
deadline=$((SECONDS + 1200))
for role in primary replica; do
  while true; do
    state=$(az vm show -g "$RG" -n "$role" --query provisioningState -o tsv 2>/dev/null || true)
    [[ $state != Failed && $state != Canceled ]] || { echo "$role provisioning $state" >&2; exit 1; }
    [[ $state != Succeeded ]] || break
    (( SECONDS < deadline )) || { echo 'Timed out provisioning VMs.' >&2; exit 1; }
    sleep 10
  done
done
# shellcheck disable=SC2034 # Serialized by save_state.
PRIMARY_IP=$(az vm show -d -g "$RG" -n primary --query publicIps -o tsv)
# shellcheck disable=SC2034 # Serialized by save_state.
REPLICA_IP=$(az vm show -d -g "$RG" -n replica --query publicIps -o tsv)
save_state
for role in primary replica; do
  deadline=$((SECONDS + 300))
  ip_variable="${role^^}_IP"
  until ssh -i .repro-ssh/id_ed25519 -o UserKnownHostsFile=.repro-ssh/known_hosts \
    -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
    "$ADMIN_USER@${!ip_variable}" true; do
    (( SECONDS < deadline )) || { echo "Timed out waiting for SSH on $role." >&2; exit 1; }
    sleep 5
  done
done
REPLICATION_PASSWORD=$(openssl rand -hex 24)
for role in primary replica; do
  { printf 'REPLICATION_PASSWORD=%q\nSTORAGE_ACCOUNT=%q\nSTORAGE_KEY=%q\n' \
      "$REPLICATION_PASSWORD" "$STORAGE_ACCOUNT" "$STORAGE_KEY"; cat setup-vm.sh; } | \
    timeout --signal=TERM --kill-after=30s 30m ./ssh.sh "$role" sudo bash -s -- "$role" "$PRIMARY_PRIVATE_IP" "$REPLICA_PRIVATE_IP" "$DISK_LAYOUT"
  if [[ $role == primary ]]; then
    # Create the repository stanza before the replica's basebackup switches WAL.
    ./ssh.sh primary sudo -u postgres pgbackrest --stanza=repro stanza-create
  fi
done
unset REPLICATION_PASSWORD STORAGE_KEY
deadline=$((SECONDS + 600))
until [[ $(./ssh.sh primary "sudo -u postgres psql -XAtc \"SELECT count(*) FROM pg_stat_replication WHERE application_name='replica' AND state='streaming' AND sync_state='sync'\"") == 1 ]]; do
  (( SECONDS < deadline )) || { echo 'Timed out waiting for the strict synchronous standby.' >&2; exit 1; }
  sleep 3
done
# Strict synchronous mode is set before the replica joins. Check archiving
# and take the baseline backup only after the standby is synchronous.
./ssh.sh primary sudo -u postgres pgbackrest --stanza=repro check
./ssh.sh primary sudo -u postgres pgbackrest --stanza=repro --type=full backup
./ssh.sh primary sudo -u postgres pgbackrest --stanza=repro info
echo 'Ready. source .repro.env; use ./ssh.sh primary or ./ssh.sh replica.'
