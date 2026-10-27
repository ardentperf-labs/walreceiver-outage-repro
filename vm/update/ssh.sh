#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source .repro.env
role=${1:-}
case "$role" in
  primary) address=$PRIMARY_IP ;;
  replica) address=$REPLICA_IP ;;
  *) echo 'Usage: ./ssh.sh primary|replica [command ...]' >&2; exit 2 ;;
esac
shift
exec ssh -i .repro-ssh/id_ed25519 -o UserKnownHostsFile=.repro-ssh/known_hosts \
  -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "${ADMIN_USER:-pgadmin}@$address" "$@"
