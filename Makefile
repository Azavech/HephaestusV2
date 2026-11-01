# Local make targets (docs/ci.md › Local make targets). `make` without a target runs `build`.

RELEASE_REPOSITORY ?= Azavech/HephaestusV2
VERSION ?=
BUILD ?=

.DEFAULT_GOAL := build
.PHONY: build test app run release check install icon clean

# Debug build of every target.
build:
	swift build

# Every test target, docs conformance tests included.
test:
	swift test

# The development bundle build/HephaestusV2.app: build number 0, so it never starts the Updater.
app:
	scripts/build-app.sh --version 0.0.0 --build 0 --repository $(RELEASE_REPOSITORY) --configuration debug --arch native

# The development bundle in the foreground of the terminal; Control-C quits it like Quit.
run: app
	build/HephaestusV2.app/Contents/MacOS/HephaestusV2

# A universal release bundle and its zip in build/, signed and notarized as in CI when the
# variables of docs/ci.md › App bundle are set; no release.json, tag or upload.
release:
	@if [ -z "$(VERSION)" ] || [ -z "$(BUILD)" ]; then echo "VERSION and BUILD are required" >&2; exit 1; fi
	scripts/build-app.sh --version $(VERSION) --build $(BUILD) --repository $(RELEASE_REPOSITORY)
	ditto -c -k --sequesterRsrc --keepParent build/HephaestusV2.app build/HephaestusV2.zip

# Runs both checks, then fails when either failed.
check:
	@status=0; \
	scripts/check-public.sh || status=1; \
	scripts/check-docs.sh || status=1; \
	exit $$status

# Installs the last bundle built. It does not quit a running HephaestusV2: quit it first.
install:
	@if [ ! -d build/HephaestusV2.app ]; then echo "build/HephaestusV2.app does not exist; run make app or make release first" >&2; exit 1; fi
	rm -rf /Applications/HephaestusV2.app
	ditto build/HephaestusV2.app /Applications/HephaestusV2.app

# Regenerates the app icon.
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

# Removes the build products.
clean:
	rm -rf .build build
