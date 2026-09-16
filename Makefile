.PHONY: bump
bump:
	@echo "🚀 Bumping Version"
	@tag=$$(svu patch) && git tag -a "$$tag" -m "Release $$tag"
	git push --tags

.PHONY: build
build:
	@echo "🚀 Building Version $(shell svu current)"
	go build -o xpost main.go

.PHONY: release
release:
	@echo "🚀 Releasing Version $(shell svu current)"
	goreleaser build --id default --clean --snapshot --single-target --output dist/xpost

.PHONY: snapshot
snapshot:
	@echo "🚀 Snapshot Version $(shell svu current)"
	goreleaser --clean --timeout 60m --snapshot
