#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f .repro.env ]]; then
  echo 'No .repro.env; no recorded resources to delete.'
  exit 0
fi
# shellcheck source=/dev/null
source .repro.env
[[ ${RG:-} == rg-walreceiver-* ]] || { echo 'Refusing unexpected resource-group name.' >&2; exit 1; }
exists=$(az group exists --name "$RG")
if [[ $exists == true ]]; then
  az group delete --name "$RG" --yes --no-wait
fi
deadline=$((SECONDS + 1200))
while :; do
  exists=$(az group exists --name "$RG")
  [[ $exists == false ]] && break
  (( SECONDS < deadline )) || { echo "Deletion pending: $RG. Retry ./cleanup.sh; state retained." >&2; exit 1; }
  sleep 10
done
# Network Watchers are shared regional resources. Preserve the baseline and any
# watcher another experiment may now use. A missing baseline alone does not
# prove that this run created a regional watcher; do not delete shared resources.
rm -rf -- .repro-ssh
rm -- .repro.env
echo "Verified resource group absent: $RG (VMs, disks, Blob backups and network resources deleted)."
