#!/bin/sh
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

    # Copy initramfs payloads (init.aa boot-guard, aa-verity-open) - these are
    # not *.sh but must reach the target so wrap_boot_initramfs can embed them.
    if [ -d "${SCRIPT_DIR}/lib/initramfs" ]; then
        ssh_exec "mkdir -p '${INSTALL_LIB_DIR}/initramfs'"
        for f in "${SCRIPT_DIR}"/lib/initramfs/*; do
            [ -f "$f" ] && scp_to_remote "$f" "${INSTALL_LIB_DIR}/initramfs/"
        done
    fi

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

    if [ "$LOCAL_MODE" = "true" ]; then
        log_debug "Local exec: $cmd"
        if [ "$DRY_RUN" = "true" ]; then
            echo "[DRY-RUN] $cmd"
            return 0
        fi
        eval "$cmd"
    else
        ssh_exec "$cmd"
    fi
}

# =============================================================================
# Remote Execution of Local Script
# =============================================================================

# Prompt (no echo) for the data-encryption passphrase on the control host and
# stage the bytes to the remote's DATA_KEYFILE (default /tmp/aa-data.key). The
# passphrase is what the operator will type at `aa-unlock`. No newline is
# written so the keyfile bytes match the interactively-entered passphrase.
stage_data_passphrase() {
    local p1 p2 tmp
    if [ -n "${AA_DATA_PASSPHRASE:-}" ]; then
        p1="$AA_DATA_PASSPHRASE"
    else
        printf 'Set the data-encryption passphrase (you will type this at aa-unlock): ' >&2
        stty -echo 2>/dev/null; read -r p1; stty echo 2>/dev/null; printf '\n' >&2
        printf 'Confirm passphrase: ' >&2
        stty -echo 2>/dev/null; read -r p2; stty echo 2>/dev/null; printf '\n' >&2
        [ "$p1" = "$p2" ] || die "passphrases do not match"
    fi
    [ -n "$p1" ] || die "empty data passphrase"
    tmp="${WORK_DIR}/aa-data.key"
    # Create the key file with 0600 BEFORE writing the secret, so it never exists
    # world-readable even briefly (the default umask would leave it 0644).
    ( umask 077; : > "$tmp" )
    printf '%s' "$p1" > "$tmp"
    scp_to_remote "$tmp" "/tmp/aa-data.key"
    # Best-effort shred + remove the transient local copy (secure_wipe_dir's
    # glob does not match aa-data.key, so shred it by name explicitly).
    command -v shred >/dev/null 2>&1 && shred -u "$tmp" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
    p1=""; p2=""
}

# Execute alpine-anywhere on the remote server
run_on_remote() {
    local extra_args="${1:-}"

    log_step "Executing on remote server..."

    # Where the alpine-anywhere CLI lives on the remote, and where to stage files.
    # Fresh install/live: scripts were deployed to INSTALL_BASE_DIR. Upgrade/slot
    # ops on an already-installed system: no deploy, use the baked CLI on PATH and
    # stage into /tmp.
    local remote_aa stage_dir
    if [ -n "$INSTALL_BASE_DIR" ]; then
        remote_aa="${INSTALL_BASE_DIR}/alpine-anywhere"
        stage_dir="$INSTALL_BASE_DIR"
    else
        remote_aa="/usr/local/bin/aa"   # baked management command
        stage_dir="/tmp"
    fi

    # Stage control-host customization inputs onto the remote, then point the
    # remote CLI at the remote copies.
    local remote_custom_script="" remote_host_key_dir="" remote_custom_files=""
    if [ -n "$CUSTOM_SCRIPT" ]; then
        scp_to_remote "$CUSTOM_SCRIPT" "${stage_dir}/aa-custom-script.sh"
        remote_custom_script="${stage_dir}/aa-custom-script.sh"
    fi
    if [ -n "$CUSTOM_FILES" ]; then
        ssh_exec "rm -rf '${stage_dir}/aa-custom-files'; mkdir -p '${stage_dir}/aa-custom-files'"
        if [ -d "$CUSTOM_FILES" ]; then
            scp_dir_to_remote "$CUSTOM_FILES" "${stage_dir}/aa-custom-files"
        else
            scp_to_remote "$CUSTOM_FILES" "${stage_dir}/aa-custom-files/"
        fi
        remote_custom_files="${stage_dir}/aa-custom-files"
    fi
    if [ -n "$SSH_HOST_KEY_DIR" ]; then
        ssh_exec "mkdir -p '${stage_dir}/aa-host-keys'"
        scp_dir_to_remote "$SSH_HOST_KEY_DIR" "${stage_dir}/aa-host-keys"
        remote_host_key_dir="${stage_dir}/aa-host-keys"
    fi
    # Stage the LUKS key material for encrypted persistence. For ssh/passphrase
    # methods we prompt on the control host (no echo) and scp the bytes to the
    # remote's default DATA_KEYFILE path; format_data_partition uses then shreds
    # it. The operator types this same passphrase later at `aa-unlock`.
    if [ "$ENCRYPT_DATA" = "true" ] && { [ "$UNLOCK_METHOD" = "ssh" ] || [ "$UNLOCK_METHOD" = "passphrase" ]; } && [ -z "$KEY_URL" ]; then
        stage_data_passphrase
    fi

    # Build the command line to pass to remote
    local remote_cmd="${remote_aa} --local"

    # Pass through relevant options. Values are shell_quote'd (defence in depth
    # on top of validate_safe_inputs) so a metacharacter in any value cannot
    # break out of the remote command line.
    [ "$VERBOSE" = "true" ] && remote_cmd="$remote_cmd -v"
    [ "$DRY_RUN" = "true" ] && remote_cmd="$remote_cmd -n"
    [ "$FORCE" = "true" ] && remote_cmd="$remote_cmd -f"
    [ -n "$ALPINE_VERSION" ] && remote_cmd="$remote_cmd -V $(shell_quote "$ALPINE_VERSION")"
    [ -n "$ALPINE_MIRROR" ] && remote_cmd="$remote_cmd -m $(shell_quote "$ALPINE_MIRROR")"
    [ -n "$KERNEL_FLAVOR" ] && remote_cmd="$remote_cmd -k $(shell_quote "$KERNEL_FLAVOR")"
    [ -n "$KERNEL_PKG" ] && remote_cmd="$remote_cmd --kernel-pkg=$(shell_quote "$KERNEL_PKG")"
    [ -n "$EXTRA_PACKAGES" ] && remote_cmd="$remote_cmd --extra-packages=$(shell_quote "$EXTRA_PACKAGES")"
    [ "$HARDENED_MODE" = "true" ] && remote_cmd="$remote_cmd --hardened"
    [ "$VERITY_MODE" = "on" ] && remote_cmd="$remote_cmd --verity"
    [ "$VERITY_MODE" = "off" ] && remote_cmd="$remote_cmd --no-verity"
    [ "$NO_VERIFY" = "true" ] && remote_cmd="$remote_cmd --no-verify"
    [ "$PERSIST_DATA" = "true" ] && remote_cmd="$remote_cmd --persist"
    [ "$ENCRYPT_DATA" = "true" ] && remote_cmd="$remote_cmd --encrypt-data"
    [ -n "$DATA_FS" ] && remote_cmd="$remote_cmd --data-fs=$(shell_quote "$DATA_FS")"
    [ -n "$UNLOCK_METHOD" ] && remote_cmd="$remote_cmd --unlock-method=$(shell_quote "$UNLOCK_METHOD")"
    [ -n "$KEY_URL" ] && remote_cmd="$remote_cmd --key-url=$(shell_quote "$KEY_URL")"
    [ "$CONTAINERS" != "none" ] && remote_cmd="$remote_cmd --containers=$(shell_quote "$CONTAINERS")"
    [ -n "$CONTAINER_RUNTIME" ] && remote_cmd="$remote_cmd --container-runtime=$(shell_quote "$CONTAINER_RUNTIME")"
    [ -n "$OVERLAY_DEVICE" ] && remote_cmd="$remote_cmd --overlay=$(shell_quote "$OVERLAY_DEVICE")"
    [ -n "$TARGET_DISK" ] && remote_cmd="$remote_cmd --disk=$(shell_quote "$TARGET_DISK")"
    [ -n "$INIT_SYSTEM" ] && remote_cmd="$remote_cmd --init=$(shell_quote "$INIT_SYSTEM")"
    [ -n "$HOSTNAME_OVERRIDE" ] && remote_cmd="$remote_cmd --hostname=$(shell_quote "$HOSTNAME_OVERRIDE")"
    [ -n "$TARGET_SLOT" ] && remote_cmd="$remote_cmd --slot=$(shell_quote "$TARGET_SLOT")"
    [ -n "$IPV4_OVERRIDE" ] && remote_cmd="$remote_cmd --ipv4=$(shell_quote "$IPV4_OVERRIDE")"
    [ -n "$IPV4_GATEWAY_OVERRIDE" ] && remote_cmd="$remote_cmd --ipv4-gateway=$(shell_quote "$IPV4_GATEWAY_OVERRIDE")"
    [ -n "$IPV6_OVERRIDE" ] && remote_cmd="$remote_cmd --ipv6=$(shell_quote "$IPV6_OVERRIDE")"
    [ -n "$IPV6_GATEWAY_OVERRIDE" ] && remote_cmd="$remote_cmd --ipv6-gateway=$(shell_quote "$IPV6_GATEWAY_OVERRIDE")"
    [ -n "$DNS_OVERRIDE" ] && remote_cmd="$remote_cmd --dns=$(shell_quote "$DNS_OVERRIDE")"
    [ "$ASSUME_YES" = "true" ] && remote_cmd="$remote_cmd --yes"
    [ -n "$remote_custom_script" ] && remote_cmd="$remote_cmd --custom-script=$(shell_quote "$remote_custom_script")"
    [ -n "$remote_custom_files" ] && remote_cmd="$remote_cmd --custom-files=$(shell_quote "$remote_custom_files")"
    [ -n "$remote_host_key_dir" ] && remote_cmd="$remote_cmd --ssh-host-keys=$(shell_quote "$remote_host_key_dir")"
    [ -n "$extra_args" ] && remote_cmd="$remote_cmd $extra_args"

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
    if [ -z "$DETECTED_INTERFACE" ]; then
        die "Could not detect default network interface"
    fi
    log_info "Detected interface: $DETECTED_INTERFACE"

    # IP address
    local ip_info
    ip_info=$(ip -4 addr show dev "$DETECTED_INTERFACE" 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}')
    if echo "$ip_info" | grep -qE '^[0-9.]+/[0-9]+$'; then
        DETECTED_IP_ADDRESS="${ip_info%/*}"
        DETECTED_CIDR="${ip_info#*/}"
        # Consumed cross-file (network.sh / install.sh), invisible to shellcheck.
        # shellcheck disable=SC2034
        DETECTED_NETMASK=$(cidr_to_netmask "$DETECTED_CIDR")
    else
        die "Could not parse IP address: $ip_info"
    fi
    log_info "Detected IP: $DETECTED_IP_ADDRESS/$DETECTED_CIDR"

    # Gateway
    DETECTED_GATEWAY=$(ip route show default 2>/dev/null | head -1 | awk '{print $3}')
    log_info "Detected gateway: $DETECTED_GATEWAY"

    # IPv6 (optional - many hosts are v4-only). Read the live kernel state:
    # the actual global unicast on the interface + the default v6 route. This
    # is the REAL active config whatever configured it (systemd-networkd,
    # ifupdown, NetworkManager, or a manual `ip` command). Skip tentative /
    # dadfailed / deprecated addresses (unusable - e.g. a DAD conflict) so we
    # never bake an address the kernel has rejected.
    local v6_info
    v6_info=$(ip -6 addr show dev "$DETECTED_INTERFACE" scope global 2>/dev/null \
        | awk '/inet6/ && !/tentative/ && !/dadfailed/ && !/deprecated/ {print $2; exit}')
    if [ -n "$v6_info" ]; then
        DETECTED_IPV6_ADDRESS="${v6_info%/*}"
        DETECTED_IPV6_CIDR="${v6_info#*/}"
        DETECTED_IPV6_GATEWAY=$(ip -6 route show default 2>/dev/null | awk '/default via/ {print $3; exit}')
        log_info "Detected IPv6: $DETECTED_IPV6_ADDRESS/$DETECTED_IPV6_CIDR via ${DETECTED_IPV6_GATEWAY:-(none)}"
    else
        log_info "No global IPv6 detected (v4-only host)"
    fi

    # DNS
    DETECTED_DNS=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -3 | tr '\n' ' ' | xargs)
    if [ -z "$DETECTED_DNS" ]; then
        DETECTED_DNS="8.8.8.8"
    fi
    log_info "Detected DNS: $DETECTED_DNS"

    # Hostname: --hostname wins over the detected one (the flag exists precisely
    # to set the node id at install; without this it was a silent no-op and the
    # image baked the pivot host's name instead).
    if [ -n "$HOSTNAME_OVERRIDE" ]; then
        DETECTED_HOSTNAME="$HOSTNAME_OVERRIDE"
    else
        DETECTED_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
    fi
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
    case "$model" in
        *"Raspberry Pi"*)
            # Consumed cross-file (install.sh / pivot.sh), invisible to shellcheck.
            # shellcheck disable=SC2034
            DETECTED_PLATFORM="rpi"
            case "$model" in
                *"Pi 5"*)
                    DETECTED_RPI_VERSION="5"
                    ;;
                *"Pi 4"*)
                    DETECTED_RPI_VERSION="4"
                    ;;
                *"Pi 3"*)
                    DETECTED_RPI_VERSION="3"
                    ;;
                *)
                    DETECTED_RPI_VERSION="generic"
                    ;;
            esac
            log_info "Detected platform: Raspberry Pi ${DETECTED_RPI_VERSION}"
            ;;
    esac

    # Reject crafted values before they reach the kernel cmdline / remote shell.
    validate_safe_inputs

    # Apply any --ipv4/--ipv6/--dns overrides on top of the live-detected
    # config (re-validates). This is also where v6 is ADDED to a v4-only host.
    apply_network_overrides
}

# =============================================================================
# Cache Management
# =============================================================================

# Download file to cache if not present
cache_download() {
    local url="$1"
    local filename="$2"
    local cache_file="${INSTALL_CACHE_DIR}/${filename}"

    if [ -f "$cache_file" ]; then
        log_info "Using cached: $filename"
        return 0
    fi

    log_info "Downloading: $filename"
    if [ "$LOCAL_MODE" = "true" ]; then
        http_fetch_file "$url" "$cache_file" || die "Failed to download: $url"
        # The kexec RAM installer boots this kernel/modloop, so a tampered mirror
        # here compromises the install. Verify against the published checksum
        # (fail closed, same policy as every other artifact).
        enforce_integrity "$url" "$cache_file"
    else
        run_cmd "if command -v curl >/dev/null 2>&1; then curl -fSL --progress-bar -o '$cache_file' '$url'; else wget -O '$cache_file' '$url'; fi"
    fi
}
