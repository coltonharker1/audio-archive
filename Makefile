# audio-archive Makefile
#
# Targets for building, testing, and installing the background daemons
# (launchd agents) that auto-process files dropped in the inbox directory.

PROJECT_ROOT := $(shell pwd)
ARCHIVE_BIN  := $(PROJECT_ROOT)/archive
DATA_DIR     := $(HOME)/.audio-archive
INBOX_DIR    := $(HOME)/audio-inbox
LAUNCH_AGENTS := $(HOME)/Library/LaunchAgents

WATCH_PLIST  := $(LAUNCH_AGENTS)/com.colton.audio-archive.watch.plist
WORKER_PLIST := $(LAUNCH_AGENTS)/com.colton.audio-archive.worker.plist

.PHONY: help build test test-race clean inbox install-daemons uninstall-daemons reinstall-daemons daemons-status logs

help:
	@echo "audio-archive targets:"
	@echo ""
	@echo "  build              Build the archive binary"
	@echo "  test               Run all tests"
	@echo "  test-race          Run all tests with the race detector"
	@echo "  clean              Remove the built binary"
	@echo ""
	@echo "  inbox              Create the inbox directory ($(INBOX_DIR))"
	@echo ""
	@echo "  install-daemons    Install and start the watch + worker launchd agents"
	@echo "  uninstall-daemons  Stop and remove the launchd agents"
	@echo "  reinstall-daemons  Rebuild + reinstall (useful after code changes)"
	@echo "  daemons-status     Show whether the daemons are loaded"
	@echo "  logs               Tail the watch and worker logs"
	@echo ""
	@echo "After install-daemons, drop audio files in $(INBOX_DIR)"
	@echo "and they will be automatically ingested, prepped, transcribed,"
	@echo "and summarized in the background."

build:
	go build -o archive ./cmd/archive/

test:
	go test ./...

test-race:
	go test -race ./...

clean:
	rm -f archive

inbox:
	@mkdir -p $(INBOX_DIR)
	@echo "Inbox ready: $(INBOX_DIR)"

# Render the plist templates with absolute paths and install them to
# ~/Library/LaunchAgents. launchctl load starts them and registers them
# for auto-start on future logins.
install-daemons: build inbox
	@mkdir -p $(DATA_DIR)/logs
	@mkdir -p $(LAUNCH_AGENTS)
	@sed -e "s|{{ARCHIVE_BIN}}|$(ARCHIVE_BIN)|g" \
	     -e "s|{{INBOX_DIR}}|$(INBOX_DIR)|g" \
	     -e "s|{{PROJECT_ROOT}}|$(PROJECT_ROOT)|g" \
	     -e "s|{{DATA_DIR}}|$(DATA_DIR)|g" \
	     scripts/launchd/com.colton.audio-archive.watch.plist.tmpl \
	     > $(WATCH_PLIST)
	@sed -e "s|{{ARCHIVE_BIN}}|$(ARCHIVE_BIN)|g" \
	     -e "s|{{PROJECT_ROOT}}|$(PROJECT_ROOT)|g" \
	     -e "s|{{DATA_DIR}}|$(DATA_DIR)|g" \
	     scripts/launchd/com.colton.audio-archive.worker.plist.tmpl \
	     > $(WORKER_PLIST)
	@# Unload first in case they're already running — load fails on a duplicate label
	@launchctl unload $(WATCH_PLIST) 2>/dev/null || true
	@launchctl unload $(WORKER_PLIST) 2>/dev/null || true
	launchctl load $(WATCH_PLIST)
	launchctl load $(WORKER_PLIST)
	@echo ""
	@echo "Daemons installed and started:"
	@echo "  watch:  processing files dropped in $(INBOX_DIR)"
	@echo "  worker: processing the job queue"
	@echo ""
	@echo "Logs: tail -f $(DATA_DIR)/logs/{watch,worker}.{log,err}"
	@echo "Or:   make logs"

uninstall-daemons:
	@launchctl unload $(WATCH_PLIST) 2>/dev/null || true
	@launchctl unload $(WORKER_PLIST) 2>/dev/null || true
	@rm -f $(WATCH_PLIST) $(WORKER_PLIST)
	@echo "Daemons uninstalled."

reinstall-daemons: uninstall-daemons install-daemons

daemons-status:
	@echo "=== watch ==="
	@launchctl list | grep audio-archive.watch 2>/dev/null || echo "  (not loaded)"
	@echo ""
	@echo "=== worker ==="
	@launchctl list | grep audio-archive.worker 2>/dev/null || echo "  (not loaded)"

logs:
	@echo "Tailing watch + worker logs. Ctrl+C to exit."
	@echo ""
	@tail -f $(DATA_DIR)/logs/watch.log $(DATA_DIR)/logs/watch.err $(DATA_DIR)/logs/worker.log $(DATA_DIR)/logs/worker.err 2>/dev/null
