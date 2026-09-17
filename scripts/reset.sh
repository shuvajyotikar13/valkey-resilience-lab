#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Removing only this lab's containers and named data volumes"
"${COMPOSE[@]}" --profile scale --profile tools down -v --remove-orphans
log "Lab reset complete"
