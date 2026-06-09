# Makefile for alpine-anywhere

.PHONY: all test test-unit test-integration install uninstall lint shellcheck syntax help clean

# Installation prefix
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib/alpine-anywhere

# Project files
MAIN_SCRIPT := alpine-anywhere
LIB_FILES := $(wildcard lib/*.sh)
# Standalone initramfs payloads (not *.sh; run before switch_root in BusyBox ash)
INITRAMFS_FILES := lib/initramfs/init.aa lib/initramfs/aa-verity-open

# Default target
all: lint test

# Run all tests
test: test-unit test-integration

# Run unit tests
test-unit:
	@echo "Running unit tests..."
	@shellspec spec/lib/

# Run integration tests
test-integration:
	@echo "Running integration tests..."
	@shellspec spec/integration/

# Run tests with coverage (requires kcov)
test-coverage:
	@echo "Running tests with coverage..."
	@shellspec --kcov

# Run tests in TAP format
test-tap:
	@shellspec --format tap

# Lint shell scripts
lint: shellcheck syntax

# Syntax-check every script with the POSIX shell (catches parse errors in the
# initramfs payloads too). Always runs even if shellcheck is absent.
syntax:
	@echo "Checking shell syntax (sh -n)..."
	@for f in $(MAIN_SCRIPT) $(LIB_FILES) $(INITRAMFS_FILES); do \
		sh -n "$$f" || exit 1; \
	done
	@echo "Syntax OK"

# Run shellcheck on all shell scripts. CI-gating (no `|| true`): a finding at
# --severity=warning or above fails the build. Skips cleanly if shellcheck is
# not installed so `make test` still works locally.
shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running shellcheck..."; \
		shellcheck -x -s sh -S warning $(MAIN_SCRIPT) $(LIB_FILES) $(INITRAMFS_FILES); \
	else \
		echo "shellcheck not installed; skipping (install it for CI gating)"; \
	fi

# Install alpine-anywhere
install:
	@echo "Installing alpine-anywhere to $(BINDIR)..."
	@mkdir -p $(BINDIR)
	@mkdir -p $(LIBDIR)
	@cp $(MAIN_SCRIPT) $(BINDIR)/alpine-anywhere
	@chmod 755 $(BINDIR)/alpine-anywhere
	@cp lib/*.sh $(LIBDIR)/
	@chmod 644 $(LIBDIR)/*.sh
	@sed -i.bak 's|SCRIPT_DIR=.*|SCRIPT_DIR="$(LIBDIR)"|; s|source "$${SCRIPT_DIR}/lib/|source "$(LIBDIR)/|' $(BINDIR)/alpine-anywhere
	@rm -f $(BINDIR)/alpine-anywhere.bak
	@echo "Installation complete!"

# Uninstall alpine-anywhere
uninstall:
	@echo "Uninstalling alpine-anywhere..."
	@rm -f $(BINDIR)/alpine-anywhere
	@rm -rf $(LIBDIR)
	@echo "Uninstallation complete!"

# Clean temporary files
clean:
	@echo "Cleaning up..."
	@rm -rf coverage/
	@rm -rf .shellspec-quick.log
	@echo "Cleanup complete!"

# Display help
help:
	@echo "alpine-anywhere - Boot any Linux server into Alpine Linux via kexec"
	@echo ""
	@echo "Available targets:"
	@echo "  all             - Lint and run all tests (default)"
	@echo "  test            - Run all tests"
	@echo "  test-unit       - Run unit tests only"
	@echo "  test-integration - Run integration tests only"
	@echo "  test-coverage   - Run tests with coverage report (requires kcov)"
	@echo "  test-tap        - Run tests in TAP format"
	@echo "  lint            - Run linters"
	@echo "  shellcheck      - Run shellcheck on all scripts"
	@echo "  install         - Install to PREFIX (default: /usr/local)"
	@echo "  uninstall       - Remove installed files"
	@echo "  clean           - Remove temporary files"
	@echo "  help            - Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX          - Installation prefix (default: /usr/local)"
	@echo "  BINDIR          - Binary directory (default: PREFIX/bin)"
	@echo "  LIBDIR          - Library directory (default: PREFIX/lib/alpine-anywhere)"
	@echo ""
	@echo "Examples:"
	@echo "  make test                  # Run all tests"
	@echo "  make install PREFIX=~/.local  # Install to ~/.local"
	@echo ""
	@echo "For usage, run: ./alpine-anywhere --help"
