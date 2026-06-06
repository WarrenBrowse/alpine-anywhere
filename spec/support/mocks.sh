#!/bin/bash
# mocks.sh - Mock functions for testing alpine-anywhere

# =============================================================================
# Mock State Variables
# =============================================================================

MOCK_SSH_RESPONSES=()
MOCK_SSH_CALL_COUNT=0
MOCK_CURL_RESPONSES=()
MOCK_CURL_CALL_COUNT=0

# =============================================================================
# Mock Reset
# =============================================================================

reset_mocks() {
    MOCK_SSH_RESPONSES=()
    MOCK_SSH_CALL_COUNT=0
    MOCK_CURL_RESPONSES=()
    MOCK_CURL_CALL_COUNT=0
}

# =============================================================================
# SSH Mocks
# =============================================================================

# Set up mock response for ssh_exec_capture
mock_ssh_response() {
    local response="$1"
    MOCK_SSH_RESPONSES+=("$response")
}

# Mock ssh_exec_capture function
mock_ssh_exec_capture() {
    local command="$1"
    local response=""

    if [[ ${#MOCK_SSH_RESPONSES[@]} -gt 0 ]]; then
        response="${MOCK_SSH_RESPONSES[$MOCK_SSH_CALL_COUNT]}"
        ((MOCK_SSH_CALL_COUNT++)) || true
    fi

    echo "$response"
}

# Mock ssh_exec function (does nothing in tests)
mock_ssh_exec() {
    local command="$1"
    log_debug "[MOCK] ssh_exec: $command"
    return 0
}

# Mock ssh_exec_sudo function
mock_ssh_exec_sudo() {
    local command="$1"
    log_debug "[MOCK] ssh_exec_sudo: $command"
    return 0
}

# =============================================================================
# SCP Mocks
# =============================================================================

# Mock scp_to_remote function
mock_scp_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    log_debug "[MOCK] scp_to_remote: $local_path -> $remote_path"
    return 0
}

# Mock scp_dir_to_remote function
mock_scp_dir_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    log_debug "[MOCK] scp_dir_to_remote: $local_path -> $remote_path"
    return 0
}

# =============================================================================
# Curl Mocks
# =============================================================================

# Set up mock response for curl
mock_curl_response() {
    local response="$1"
    MOCK_CURL_RESPONSES+=("$response")
}

# Mock curl function
mock_curl() {
    local response=""

    if [[ ${#MOCK_CURL_RESPONSES[@]} -gt 0 ]]; then
        response="${MOCK_CURL_RESPONSES[$MOCK_CURL_CALL_COUNT]}"
        ((MOCK_CURL_CALL_COUNT++)) || true
    fi

    echo "$response"
}

# =============================================================================
# Network Mocks
# =============================================================================

# Mock function to simulate network detection
mock_detect_interface() {
    DETECTED_INTERFACE="eth0"
    echo "$DETECTED_INTERFACE"
}

mock_detect_ip_address() {
    DETECTED_IP_ADDRESS="192.168.1.100"
    DETECTED_CIDR="24"
    DETECTED_NETMASK="255.255.255.0"
}

mock_detect_gateway() {
    DETECTED_GATEWAY="192.168.1.1"
}

mock_detect_dns() {
    DETECTED_DNS="8.8.8.8 8.8.4.4"
}

mock_detect_hostname() {
    DETECTED_HOSTNAME="testhost"
}

# =============================================================================
# Test Data Generators
# =============================================================================

# Generate sample /proc/meminfo output
generate_mock_meminfo() {
    local mem_kb="${1:-2097152}"  # Default 2GB
    echo "MemTotal:        $mem_kb kB"
}

# Generate sample ip route output
generate_mock_ip_route() {
    local gateway="${1:-192.168.1.1}"
    local interface="${2:-eth0}"
    echo "default via $gateway dev $interface proto static metric 100"
}

# Generate sample ip addr output
generate_mock_ip_addr() {
    local ip="${1:-192.168.1.100}"
    local cidr="${2:-24}"
    local interface="${3:-eth0}"
    echo "    inet $ip/$cidr brd ${ip%.*}.255 scope global $interface"
}

# Generate sample resolv.conf
generate_mock_resolv_conf() {
    local dns1="${1:-8.8.8.8}"
    local dns2="${2:-8.8.4.4}"
    echo "nameserver $dns1"
    echo "nameserver $dns2"
}

# Generate sample os-release
generate_mock_os_release() {
    local name="${1:-Alpine Linux}"
    local version="${2:-3.20}"
    cat <<EOF
NAME="$name"
ID=alpine
VERSION_ID=$version
PRETTY_NAME="$name v$version"
EOF
}

# =============================================================================
# Assertion Helpers
# =============================================================================

# Check if a string contains a substring
assert_contains() {
    local haystack="$1"
    local needle="$2"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "Expected '$haystack' to contain '$needle'" >&2
        return 1
    fi
}

# Check if a file exists
assert_file_exists() {
    local file="$1"

    if [[ -f "$file" ]]; then
        return 0
    else
        echo "Expected file '$file' to exist" >&2
        return 1
    fi
}

# Check if a directory exists
assert_dir_exists() {
    local dir="$1"

    if [[ -d "$dir" ]]; then
        return 0
    else
        echo "Expected directory '$dir' to exist" >&2
        return 1
    fi
}
