#!/bin/bash
# spec_helper.sh - ShellSpec test configuration and helpers

# Get the project root directory
SPEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SPEC_DIR")"

# Source mock functions
. "$SPEC_DIR/support/mocks.sh"

# Set default test environment variables
setup_test_env() {
    # Prevent actual execution
    DRY_RUN=true
    VERBOSE=false
    FORCE=true

    # Set default values
    ALPINE_VERSION="3.20"
    ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
    KERNEL_FLAVOR="lts"
    SSH_PORT="22"
    SSH_IDENTITY=""
    EXTRA_PACKAGES=""
    REBOOT_DELAY="5"
    TARGET_HOST="test-host"
    TARGET_USER="root"

    # Working directories
    WORK_DIR="/tmp/test-alpine-anywhere"
    REMOTE_WORK_DIR="/tmp/alpine-anywhere"

    # Network detection results (test defaults)
    DETECTED_INTERFACE="eth0"
    DETECTED_IP_ADDRESS="192.168.1.100"
    DETECTED_NETMASK="255.255.255.0"
    DETECTED_CIDR="24"
    DETECTED_GATEWAY="192.168.1.1"
    DETECTED_DNS="8.8.8.8 8.8.4.4"
    DETECTED_HOSTNAME="testhost"
    DETECTED_ARCH="x86_64"
    NETWORK_IS_DHCP=false
}

# Reset test environment
reset_test_env() {
    setup_test_env
    reset_mocks
}

# ShellSpec hooks
spec_helper_precheck() {
    : # Called before loading specs
}

spec_helper_loaded() {
    setup_test_env
}

spec_helper_configure() {
    : # Called to configure shellspec
}

# Helper to create a temporary directory for tests
create_test_work_dir() {
    WORK_DIR=$(mktemp -d -t test-alpine-anywhere.XXXXXX)
    mkdir -p "$WORK_DIR"
}

# Helper to cleanup test work directory
cleanup_test_work_dir() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
