SHELL := /usr/bin/env bash

.PHONY: init build up reset status preload envelope baseline replica-partial replica-full \
	reshard-atomic reshard-legacy bgsave failover-none failover-immediate \
	failover-jitter add-replicas hot-skew report check

init:
	@if [[ ! -f .env ]]; then cp env.example .env; echo "Created .env from env.example"; fi

build: init
	podman compose --profile tools build loadgen

up: init
	bash ./scripts/bootstrap.sh

reset:
	bash ./scripts/reset.sh

status:
	podman compose ps
	@podman compose exec -T valkey-1 valkey-cli -h 127.0.0.1 -p 6379 --cluster check valkey-1:6379 || true

preload:
	bash ./scripts/preload.sh

envelope:
	bash ./scripts/run-envelope.sh

baseline:
	bash ./scripts/run-scenario.sh baseline

replica-partial:
	bash ./scripts/run-scenario.sh replica-partial

replica-full:
	bash ./scripts/run-scenario.sh replica-full

reshard-atomic:
	bash ./scripts/run-scenario.sh reshard-atomic

reshard-legacy:
	bash ./scripts/run-scenario.sh reshard-legacy

bgsave:
	bash ./scripts/run-scenario.sh bgsave

failover-none:
	bash ./scripts/run-scenario.sh failover-none

failover-immediate:
	bash ./scripts/run-scenario.sh failover-immediate

failover-jitter:
	bash ./scripts/run-scenario.sh failover-jitter

add-replicas:
	bash ./scripts/run-scenario.sh add-replicas

hot-skew:
	bash ./scripts/run-scenario.sh hot-skew

report:
	@test -n "$(RUN)" || (echo "Usage: make report RUN=results/<run-directory>" && exit 2)
	python3 scripts/report.py "$(RUN)"

check:
	bash -n scripts/*.sh
	python3 -m py_compile scripts/*.py
	podman compose config >/dev/null

.PHONY: betterdb-up betterdb-down betterdb-status

# Optional observability stack; persistent history is in an external volume.
betterdb-up: up
	bash ./scripts/betterdb-up.sh

betterdb-down:
	podman compose -f docker-compose.yml -f docker-compose.betterdb.yml --profile betterdb stop betterdb betterdb-postgres

betterdb-status:
	podman compose -f docker-compose.yml -f docker-compose.betterdb.yml --profile betterdb ps
	@curl -fsS http://127.0.0.1:3001/api/health || true
