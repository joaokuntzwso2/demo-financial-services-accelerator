.PHONY: start stop reset test verify logs
start:
	./start.sh
stop:
	./stop.sh
reset:
	./reset.sh
test:
	cd backend && go test ./...
	for f in start.sh stop.sh reset.sh logs.sh scripts/*.sh bootstrap/*.sh demo/*.sh; do bash -n $$f; done
verify:
	./scripts/verify.sh
logs:
	./logs.sh
