SHELL := /usr/bin/env bash

.PHONY: build up reset status preload envelope baseline replica-partial replica-full \
	reshard-atomic reshard-legacy bgsave failover-none failover-immediate \
	failover-jitter add-replicas hot-skew report check

build:
	docker compose build loadgen

up:
	./scripts/bootstrap.sh

reset:
	./scripts/reset.sh

status:
	docker compose ps
	@docker compose exec -T valkey-1 valkey-cli -h 127.0.0.1 -p 6379 --cluster check valkey-1:6379 || true

preload:
	./scripts/preload.sh

envelope:
	./scripts/run-envelope.sh

baseline:
	./scripts/run-scenario.sh baseline

replica-partial:
	./scripts/run-scenario.sh replica-partial

replica-full:
	./scripts/run-scenario.sh replica-full

reshard-atomic:
	./scripts/run-scenario.sh reshard-atomic

reshard-legacy:
	./scripts/run-scenario.sh reshard-legacy

bgsave:
	./scripts/run-scenario.sh bgsave

failover-none:
	./scripts/run-scenario.sh failover-none

failover-immediate:
	./scripts/run-scenario.sh failover-immediate

failover-jitter:
	./scripts/run-scenario.sh failover-jitter

add-replicas:
	./scripts/run-scenario.sh add-replicas

hot-skew:
	./scripts/run-scenario.sh hot-skew

report:
	@test -n "$(RUN)" || (echo "Usage: make report RUN=results/<run-directory>" && exit 2)
	python3 scripts/report.py "$(RUN)"

check:
	bash -n scripts/*.sh
	python3 -m py_compile scripts/report.py
	docker compose config >/dev/null
