#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -e .repro.env ]]; then
  echo 'Run ./cleanup.sh before provisioning again.' >&2
  exit 1
fi
RG="rg-walreceiver-$(date -u +%Y%m%d-%H%M%S)-$RANDOM"
LOCATION="${LOCATION:-eastus}"
STORAGE_ACCOUNT="walr$(date -u +%y%m%d%H%M%S)$RANDOM"
export KUBECONFIG="$PWD/kubeconfig"
umask 077
printf 'RG=%q\nSTORAGE_ACCOUNT=%q\nexport KUBECONFIG=%q\n' \
  "$RG" "$STORAGE_ACCOUNT" "$KUBECONFIG" > .repro.env
trap './cleanup.sh; exit 1' ERR INT TERM
az group create -n "$RG" -l "$LOCATION" -o none
az storage account create -g "$RG" -n "$STORAGE_ACCOUNT" -l "$LOCATION" \
  --sku Standard_LRS -o none
az aks create -g "$RG" -n repro --node-count 2 --node-vm-size Standard_D2s_v6 \
  --tier free --generate-ssh-keys -o none
az aks get-credentials -g "$RG" -n repro --file "$KUBECONFIG" -o none
printf 'NODE_RG=%q\n' "$(az aks show -g "$RG" -n repro --query nodeResourceGroup -o tsv)" >> .repro.env
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.1.yaml
kubectl rollout status -n cnpg-system deployment/cnpg-controller-manager --timeout=5m
# Pass the Blob key directly to Kubernetes without printing it or writing it to disk.
STORAGE_KEY=$(az storage account keys list -g "$RG" -n "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)
AZURE_STORAGE_ACCOUNT="$STORAGE_ACCOUNT" AZURE_STORAGE_KEY="$STORAGE_KEY" \
  az storage container create --name backups --auth-mode key -o none
printf '%s' "$STORAGE_KEY" | kubectl create secret generic azure \
  --from-literal=account="$STORAGE_ACCOUNT" --from-file=key=/dev/stdin
unset STORAGE_KEY
sed "s/AZURE_ACCOUNT/$STORAGE_ACCOUNT/" postgres.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready cluster/postgres --timeout=20m
kubectl get pods -l cnpg.io/cluster=postgres -o wide
