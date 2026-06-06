#!/bin/bash
# exec.sh - Unified execution layer for local and remote modes
#
# All variables are declared in common.sh

# =============================================================================
# Directory Setup
# =============================================================================

# Setup installation directories (sets paths based on home dir)
setup_install_dirs() {
    local home_dir="${1:-$HOME}"
    INSTALL_BASE_DIR="${home_dir}/.local/share/alpine-anywhere"
    INSTALL_LIB_DIR="${INSTALL_BASE_DIR}/lib"
    INSTALL_CACHE_DIR="${INSTALL_BASE_DIR}/cache"
    INSTALL_LOG_DIR="${INSTALL_BASE_DIR}/log"
}

# Create directory structure on target
create_install_dirs() {
    run_cmd "mkdir -p '${INSTALL_BASE_DIR}' '${INSTALL_LIB_DIR}' '${INSTALL_CACHE_DIR}' '${INSTALL_LOG_DIR}'"
}

# =============================================================================
# Script Deployment
# =============================================================================

# Copy scripts to remote server
deploy_scripts_to_remote() {
    log_step "Deploying scripts to remote server..."

    # Detect remote home and setup paths
    local remote_home
    remote_home=$(ssh_exec_capture 'echo $HOME')
    setup_install_dirs "$remote_home"

    log_debug "Remote install dir: ${INSTALL_BASE_DIR}"

    # Create directories
    ssh_exec "mkdir -p '${INSTALL_BASE_DIR}' '${INSTALL_LIB_DIR}' '${INSTALL_CACHE_DIR}' '${INSTALL_LOG_DIR}'"

    # Copy main script to base dir
    log_info "Copying scripts..."
    scp_to_remote "${SCRIPT_DIR}/alpine-anywhere" "${INSTALL_BASE_DIR}/"

    # Copy all library files
    for lib in "${SCRIPT_DIR}"/lib/*.sh; do
        scp_to_remote "$lib" "${INSTALL_LIB_DIR}/"
    done

    # Make executable
    ssh_exec "chmod +x '${INSTALL_BASE_DIR}/alpine-anywhere'"

    log_info "Scripts deployed to ${INSTALL_BASE_DIR}/"
}

# =============================================================================
# Unified Execution Wrappers
# =============================================================================

# Run a command (locally or via SSH depending on mode)
run_cmd() {
    local cmd="$1"

    if [[ "$LOCAL_MODE" == "true" ]]; then
        log_debug "Local exec: $cmd"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY-RUN] $cmd"
            return 0
        fi
        eval "$cmd"
    else
        ssh_exec "$cmd"
    fi
}

# Run a command with sudo
run_cmd_sudo() {
    local cmd="$1"

    if [[ "$LOCAL_MODE" == "true" ]]; then
        log_debug "Local sudo: $cmd"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY-RUN] sudo $cmd"
            return 0
        fi
        if [[ $EUID -eq 0 ]]; then
            eval "$cmd"
        else
            sudo sh -c "$cmd"
        fi
    else
        ssh_exec_sudo "$cmd"
    fi
}

# Run a command and capture output
run_cmd_capture() {
    local cmd="$1"

    if [[ "$LOCAL_MODE" == "true" ]]; then
        log_debug "Local capture: $cmd"
        eval "$cmd"
    else
        ssh_exec_capture "$cmd"
    fi
}

# Copy file to target (in local mode, just copies locally)
copy_to_target() {
    local local_path="$1"
    local remote_path="$2"

    if [[ "$LOCAL_MODE" == "true" ]]; then
        log_debug "Local copy: $local_path -> $remote_path"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY-RUN] cp '$local_path' '$remote_path'"
            return 0
        fi
        cp "$local_path" "$remote_path"
    else
        scp_to_remote "$local_path" "$remote_path"
    fi
}

# =============================================================================
# Remote Execution of Local Script
# =============================================================================

# Execute alpine-anywhere on the remote server
run_on_remote() {
    local extra_args="${1:-}"

    log_step "Executing on remote server..."

    # Build the command line to pass to remote
    local remote_cmd="${INSTALL_BASE_DIR}/alpine-anywhere --local"

    # Pass through relevant options
    [[ "$VERBOSE" == "true" ]] && remote_cmd+=" -v"
    [[ "$DRY_RUN" == "true" ]] && remote_cmd+=" -n"
    [[ "$FORCE" == "true" ]] && remote_cmd+=" -f"
    [[ -n "$ALPINE_VERSION" ]] && remote_cmd+=" -V '$ALPINE_VERSION'"
    [[ -n "$ALPINE_MIRROR" ]] && remote_cmd+=" -m '$ALPINE_MIRROR'"
    [[ -n "$KERNEL_FLAVOR" ]] && remote_cmd+=" -k '$KERNEL_FLAVOR'"
    [[ "$INSTALL_METHOD" != "auto" ]] && remote_cmd+=" --method='$INSTALL_METHOD'"
    [[ -n "$EXTRA_PACKAGES" ]] && remote_cmd+=" --extra-packages='$EXTRA_PACKAGES'"
    [[ -n "$extra_args" ]] && remote_cmd+=" $extra_args"

    log_debug "Remote command: $remote_cmd"

    # Execute on remote with interactive TTY for sudo
    ssh_exec_interactive "$remote_cmd"
}

# =============================================================================
# Local System Detection
# =============================================================================

# Detect local network configuration (for local mode)
detect_local_network() {
    log_step "Detecting local network configuration..."

    # Interface
    DETECTED_INTERFACE=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    if [[ -z "$DETECTED_INTERFACE" ]]; then
        die "Could not detect default network interface"
    fi
    log_info "Detected interface: $DETECTED_INTERFACE"

    # IP address
    local ip_info
    ip_info=$(ip -4 addr show dev "$DETECTED_INTERFACE" 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}')
    if [[ "$ip_info" =~ ^([0-9.]+)/([0-9]+)$ ]]; then
        DETECTED_IP_ADDRESS="${BASH_REMATCH[1]}"
        DETECTED_CIDR="${BASH_REMATCH[2]}"
        DETECTED_NETMASK=$(cidr_to_netmask "$DETECTED_CIDR")
    else
        die "Could not parse IP address: $ip_info"
    fi
    log_info "Detected IP: $DETECTED_IP_ADDRESS/$DETECTED_CIDR"

    # Gateway
    DETECTED_GATEWAY=$(ip route show default 2>/dev/null | head -1 | awk '{print $3}')
    log_info "Detected gateway: $DETECTED_GATEWAY"

    # DNS
    DETECTED_DNS=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -3 | tr '\n' ' ' | xargs)
    if [[ -z "$DETECTED_DNS" ]]; then
        DETECTED_DNS="8.8.8.8"
    fi
    log_info "Detected DNS: $DETECTED_DNS"

    # Hostname
    DETECTED_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
    DETECTED_HOSTNAME=$(echo "$DETECTED_HOSTNAME" | tr -cd '[:alnum:]-' | head -c 63)
    log_info "Detected hostname: $DETECTED_HOSTNAME"

    # DHCP status
    NETWORK_IS_DHCP=false
    if pgrep -x dhclient >/dev/null 2>&1 || pgrep -x dhcpcd >/dev/null 2>&1; then
        NETWORK_IS_DHCP=true
    fi
    log_info "Network type: $([ "$NETWORK_IS_DHCP" = "true" ] && echo "DHCP" || echo "Static")"

    # Architecture
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) DETECTED_ARCH="x86_64" ;;
        aarch64|arm64) DETECTED_ARCH="aarch64" ;;
        armv7l|armhf) DETECTED_ARCH="armv7" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac
    log_info "Detected architecture: $DETECTED_ARCH"

    # Platform detection (RPi, etc.)
    DETECTED_PLATFORM="generic"
    DETECTED_RPI_VERSION=""
    local model=""
    model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || true)
    if [[ "$model" == *"Raspberry Pi"* ]]; then
        DETECTED_PLATFORM="rpi"
        if [[ "$model" == *"Pi 5"* ]]; then
            DETECTED_RPI_VERSION="5"
        elif [[ "$model" == *"Pi 4"* ]] || [[ "$model" == *"Pi 400"* ]]; then
            DETECTED_RPI_VERSION="4"
        elif [[ "$model" == *"Pi 3"* ]]; then
            DETECTED_RPI_VERSION="3"
        else
            DETECTED_RPI_VERSION="generic"
        fi
        log_info "Detected platform: Raspberry Pi ${DETECTED_RPI_VERSION}"
    fi
}

# =============================================================================
# Cache Management
# =============================================================================

# Check if a file exists in cache
cache_exists() {
    local filename="$1"
    [[ -f "${INSTALL_CACHE_DIR}/${filename}" ]]
}

# Get path to cached file
cache_path() {
    local filename="$1"
    echo "${INSTALL_CACHE_DIR}/${filename}"
}

# Download file to cache if not present
cache_download() {
    local url="$1"
    local filename="$2"
    local cache_file="${INSTALL_CACHE_DIR}/${filename}"

    if [[ -f "$cache_file" ]]; then
        log_info "Using cached: $filename"
        return 0
    fi

    log_info "Downloading: $filename"
    if [[ "$LOCAL_MODE" == "true" ]]; then
        curl -fSL --progress-bar -o "$cache_file" "$url"
    else
        run_cmd "curl -fSL --progress-bar -o '$cache_file' '$url'"
    fi
}
