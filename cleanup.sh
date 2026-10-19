#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source .repro.env
# Deletes AKS, its managed node group/disks, and the Blob account/backups.
az group delete --name "$RG" --yes
test "$(az group exists --name "$RG")" = false
[[ -z ${NODE_RG:-} ]] || test "$(az group exists --name "$NODE_RG")" = false
[[ ! -f kubeconfig ]] || rm -- kubeconfig
rm -- .repro.env
