# DayPilot — developer harness
#
#   make setup      scaffold the source tree and validate the toolchain
#   make build      compile the release binary
#   make run        package the signed app and open it
#   make install    package and copy DayPilot.app into /Applications
#   make snapshots  capture the app's own windows to PNG
#   make selftest   run the system health check and exit
#   make clean      remove build artifacts

PRODUCT     := DayPilot
BINDIR      := .build/release
BINARY      := $(BINDIR)/$(PRODUCT)
APPBUNDLE   := $(PRODUCT).app
DIST_DIR    := dist
APP_PATH    := $(DIST_DIR)/$(APPBUNDLE)
ICNS        := Resources/AppIcon.icns

.DEFAULT_GOAL := help

.PHONY: help setup build run selftest integration-test icon package install snapshots clean

help:
	@printf '%s\n' \
		'DayPilot — developer harness' \
		'' \
		'  make setup      scaffold the source tree and validate the toolchain' \
		'  make build      compile the release binary' \
		'  make run        package the signed app and open it' \
		'  make icon       render Resources/AppIcon.icns' \
		'  make package    build, sign and verify dist/$(APPBUNDLE)' \
		'  make install    copy the packaged app into /Applications' \
		'  make snapshots  capture the windows to PNG, no permissions needed' \
		'  make selftest   run the system health check and exit' \
		'  make integration-test  full synthesis run (needs a provider key or a mock)' \
		'  make clean      remove build artifacts'

setup:
	@./bootstrap.sh

build:
	swift build -c release --product $(PRODUCT)

# Packages the app, then opens the signed bundle the way a user would open it.
run: package
	@open "$(APP_PATH)"

selftest: build
	@exec $(BINARY) --selftest

# End-to-end run of the synthesis pipeline: prompt assembly, the API call,
# report archival, memory update, and 10s of spoken audio. Reads the skill
# config for the provider, and DAYPILOT_CONFIG to point somewhere else.
integration-test: build
	@exec $(BINARY) --integration-test

# Renders AppIcon.icns from nothing: a drawn squircle, radar rings and a focal
# point, then iconutil to package it.
icon:
	@python3 Scripts/generate_icon.py --output $(ICNS)

# Build, bundle, sign and verify. The script assembles the bundle in a scratch
# directory, because this project directory is file-provider managed.
package:
	@bash Scripts/package_app.sh

# Copies the packaged app into /Applications, where Launchpad, Spotlight and the
# Screen Recording list find it. A running copy is quit first, so the replacement
# is never written underneath it.
install: package
	@osascript -e 'if application id "com.daypilot.app" is running then tell application id "com.daypilot.app" to quit' >/dev/null 2>&1 || true
	@rm -rf "/Applications/$(APPBUNDLE)"
	@ditto "$(APP_PATH)" "/Applications/$(APPBUNDLE)" || { echo 'install failed'; exit 1; }
	@printf '\n%s\n' "Installed /Applications/$(APPBUNDLE). Open it from Launchpad or Spotlight."

clean:
	rm -rf .build .swiftpm $(DIST_DIR)
	@printf 'Removed build artifacts\n'

# Launches the packaged app with sample content and captures its own windows, in
# light and dark appearance, to PNG files in dist/previews. The bundle is the
# binary a user runs, so the captures show the real activation policy and Dock
# presence. Only the app's own drawing is captured, so no permission is needed.
SNAPSHOT_BINARY := $(APP_PATH)/Contents/MacOS/$(PRODUCT)

snapshots: package
	@$(SNAPSHOT_BINARY) --preview-fixtures --no-capture --snapshot-appearance light --snapshot-windows $(DIST_DIR)/previews
	@$(SNAPSHOT_BINARY) --preview-fixtures --no-capture --snapshot-appearance dark --snapshot-windows $(DIST_DIR)/previews
