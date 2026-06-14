#!/bin/sh
# network.sh - Network configuration detection for alpine-anywhere

# =============================================================================
# Network Detection Functions
# =============================================================================

# Detect the default network interface
detect_interface() {
    log_step "Detecting network interface..."

    local interface
    interface=$(ssh_exec_capture "ip route show default 2>/dev/null | head -1 | awk '{print \$5}'")

    if [ -z "$interface" ]; then
        die "Could not detect default network interface"
    fi

    DETECTED_INTERFACE="$interface"
    log_info "Detected interface: $DETECTED_INTERFACE"
}

# Detect IP address and CIDR/netmask
detect_ip_address() {
    log_step "Detecting IP address..."

    local ip_info
    ip_info=$(ssh_exec_capture "ip -4 addr show dev '$DETECTED_INTERFACE' 2>/dev/null | grep 'inet ' | head -1 | awk '{print \$2}'")

    if [ -z "$ip_info" ]; then
        die "Could not detect IP address on $DETECTED_INTERFACE"
    fi

    # Parse IP and CIDR
    if echo "$ip_info" | grep -qE '^[0-9.]+/[0-9]+$'; then
        DETECTED_IP_ADDRESS="${ip_info%/*}"
        DETECTED_CIDR="${ip_info#*/}"
        DETECTED_NETMASK=$(cidr_to_netmask "$DETECTED_CIDR")
    else
        die "Could not parse IP address: $ip_info"
    fi

    log_info "Detected IP: $DETECTED_IP_ADDRESS/$DETECTED_CIDR ($DETECTED_NETMASK)"
}

# Detect default gateway
detect_gateway() {
    log_step "Detecting gateway..."

    local gateway
    gateway=$(ssh_exec_capture "ip route show default 2>/dev/null | head -1 | awk '{print \$3}'")

    if [ -z "$gateway" ]; then
        die "Could not detect default gateway"
    fi

    DETECTED_GATEWAY="$gateway"
    log_info "Detected gateway: $DETECTED_GATEWAY"
}

# Detect IPv6 (optional - many hosts are v4-only). Reads the remote live
# kernel state, skipping tentative/dadfailed/deprecated/link-local. Never
# fatal: absence just means a v4-only host (v6 can still be added via --ipv6).
detect_ipv6() {
    log_step "Detecting IPv6..."
    local v6_info
    v6_info=$(ssh_exec_capture "ip -6 addr show dev '$DETECTED_INTERFACE' scope global 2>/dev/null | awk '/inet6/ && !/tentative/ && !/dadfailed/ && !/deprecated/ {print \$2; exit}'" || true)
    if [ -n "$v6_info" ]; then
        DETECTED_IPV6_ADDRESS="${v6_info%/*}"
        DETECTED_IPV6_CIDR="${v6_info#*/}"
        DETECTED_IPV6_GATEWAY=$(ssh_exec_capture "ip -6 route show default 2>/dev/null | awk '/default via/ {print \$3; exit}'" || true)
        log_info "Detected IPv6: $DETECTED_IPV6_ADDRESS/$DETECTED_IPV6_CIDR via ${DETECTED_IPV6_GATEWAY:-(none)}"
    else
        log_info "No global IPv6 detected (v4-only host)"
    fi
}

# Detect DNS servers
detect_dns() {
    log_step "Detecting DNS servers..."

    local dns=""

    # Try systemd-resolved first
    dns=$(ssh_exec_capture "resolvectl dns 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -3 | tr '\n' ' '" || true)

    # Try nmcli
    if [ -z "$dns" ]; then
        dns=$(ssh_exec_capture "nmcli dev show 2>/dev/null | grep 'DNS' | awk '{print \$2}' | head -3 | tr '\n' ' '" || true)
    fi

    # Fall back to resolv.conf
    if [ -z "$dns" ]; then
        dns=$(ssh_exec_capture "grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print \$2}' | head -3 | tr '\n' ' '" || true)
    fi

    # Clean up whitespace
    dns=$(echo "$dns" | xargs)

    if [ -z "$dns" ]; then
        log_warn "Could not detect DNS servers, using default 8.8.8.8"
        dns="8.8.8.8"
    fi

    DETECTED_DNS="$dns"
    log_info "Detected DNS: $DETECTED_DNS"
}

# Detect hostname
detect_hostname() {
    log_step "Detecting hostname..."

    local hostname
    hostname=$(ssh_exec_capture "hostname -s 2>/dev/null || hostname")

    if [ -z "$hostname" ]; then
        hostname="alpine"
    fi

    # Sanitize hostname (alphanumeric and hyphens only)
    hostname=$(echo "$hostname" | tr -cd '[:alnum:]-' | head -c 63)

    DETECTED_HOSTNAME="$hostname"
    log_info "Detected hostname: $DETECTED_HOSTNAME"
}

# Detect if network is using DHCP
detect_dhcp_status() {
    log_step "Detecting DHCP status..."

    local is_dhcp=false

    # Check for dhclient
    if ssh_exec_capture "pgrep -x dhclient >/dev/null 2>&1"; then
        is_dhcp=true
    fi

    # Check for dhcpcd
    if ssh_exec_capture "pgrep -x dhcpcd >/dev/null 2>&1"; then
        is_dhcp=true
    fi

    # Check NetworkManager connection type
    local nm_method
    nm_method=$(ssh_exec_capture "nmcli -t -f GENERAL.CONNECTION dev show '$DETECTED_INTERFACE' 2>/dev/null | cut -d: -f2" || true)
    if [ -n "$nm_method" ]; then
        local conn_method
        conn_method=$(ssh_exec_capture "nmcli -t -f ipv4.method con show '$nm_method' 2>/dev/null | cut -d: -f2" || true)
        if [ "$conn_method" = "auto" ]; then
            is_dhcp=true
        fi
    fi

    # Check systemd-networkd
    if ssh_exec_capture "systemctl is-active systemd-networkd >/dev/null 2>&1"; then
        local networkd_dhcp
        networkd_dhcp=$(ssh_exec_capture "grep -l 'DHCP=yes' /etc/systemd/network/*.network 2>/dev/null" || true)
        if [ -n "$networkd_dhcp" ]; then
            is_dhcp=true
        fi
    fi

    NETWORK_IS_DHCP="$is_dhcp"
    if [ "$NETWORK_IS_DHCP" = "true" ]; then
        log_info "Network type: DHCP"
    else
        log_info "Network type: Static"
    fi
}

# =============================================================================
# Architecture Detection
# =============================================================================

# Platform type (generic, rpi, etc.)
DETECTED_PLATFORM="generic"
DETECTED_RPI_VERSION=""

detect_architecture() {
    log_step "Detecting architecture..."

    local arch
    arch=$(ssh_exec_capture "uname -m")

    case "$arch" in
        x86_64|amd64)
            DETECTED_ARCH="x86_64"
            ;;
        aarch64|arm64)
            DETECTED_ARCH="aarch64"
            # Check if this is a Raspberry Pi
            detect_raspberry_pi
            ;;
        armv7l|armhf)
            DETECTED_ARCH="armv7"
            detect_raspberry_pi
            ;;
        *)
            die "Unsupported architecture: $arch"
            ;;
    esac

    log_info "Detected architecture: $DETECTED_ARCH"
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        log_info "Detected platform: Raspberry Pi ${DETECTED_RPI_VERSION}"
    fi
}

# Detect if running on Raspberry Pi
detect_raspberry_pi() {
    log_debug "Checking for Raspberry Pi..."

    local model=""

    # Try device-tree model
    model=$(ssh_exec_capture "cat /proc/device-tree/model 2>/dev/null | tr -d '\0'" || true)

    # Fallback to cpuinfo
    if [ -z "$model" ]; then
        model=$(ssh_exec_capture "grep -i 'model' /proc/cpuinfo 2>/dev/null | head -1" || true)
    fi

    case "$model" in
        *"Raspberry Pi"*)
            DETECTED_PLATFORM="rpi"

            # Detect RPi version for kernel selection
            case "$model" in
                *"Pi 5"*)
                    DETECTED_RPI_VERSION="5"
                    ;;
                *"Pi 4"*|*"Pi 400"*)
                    DETECTED_RPI_VERSION="4"
                    ;;
                *"Pi 3"*)
                    DETECTED_RPI_VERSION="3"
                    ;;
                *"Pi 2"*)
                    DETECTED_RPI_VERSION="2"
                    ;;
                *)
                    DETECTED_RPI_VERSION="generic"
                    ;;
            esac

            log_debug "Raspberry Pi detected: $model (version: $DETECTED_RPI_VERSION)"
            ;;
    esac
}

# =============================================================================
# Run All Network Detection
# =============================================================================

detect_all_network_config() {
    log_step "Detecting network configuration..."

    detect_interface
    detect_ip_address
    detect_gateway
    detect_ipv6
    detect_dns
    detect_hostname
    detect_dhcp_status
    detect_architecture

    # Detected values feed the kernel cmdline (root=, ip=, ...) where quoting
    # offers no protection; a compromised remote could return crafted values.
    validate_safe_inputs

    # Apply --ipv4/--ipv6/--dns overrides on top (re-validates); also the path
    # that ADDS v6 to a v4-only remote host (FDC static /64 case).
    apply_network_overrides
}

# =============================================================================
# Network Configuration Generation
# =============================================================================

# Generate /etc/network/interfaces content.
#
# Emits the IPv4 stanza (dhcp or static) and, when an IPv6 address is set,
# an `inet6 static` stanza on the same interface (ifupdown-ng handles both
# families on one iface). The interface name is taken as `$1` when given
# (the s6 network-up passes the runtime-resolved name), else
# $DETECTED_INTERFACE.
generate_interfaces_config() {
    _gic_if="${1:-$DETECTED_INTERFACE}"
    cat <<EOF
auto lo
iface lo inet loopback

auto $_gic_if
EOF

    if [ "$NETWORK_IS_DHCP" = "true" ]; then
        cat <<EOF
iface $_gic_if inet dhcp
EOF
    else
        cat <<EOF
iface $_gic_if inet static
    address $DETECTED_IP_ADDRESS
    netmask $DETECTED_NETMASK
    gateway $DETECTED_GATEWAY
EOF
    fi

    # IPv6 (optional): static stanza when an address is configured. A bare
    # gateway (no address) is invalid, so both are required to emit it.
    if [ -n "$DETECTED_IPV6_ADDRESS" ]; then
        cat <<EOF

iface $_gic_if inet6 static
    address $DETECTED_IPV6_ADDRESS
    netmask ${DETECTED_IPV6_CIDR:-64}
EOF
        if [ -n "$DETECTED_IPV6_GATEWAY" ]; then
            echo "    gateway $DETECTED_IPV6_GATEWAY"
        fi
    fi
}

# Apply user-supplied --ipv4/--ipv6/--*-gateway/--dns overrides on top of the
# live-detected values. IPv6 overrides ADD v6 to a v4-only host (FDC: a box
# with no v6 on the source, given a static /64 to bake in). Each override is
# ADDR/PREFIX; gateways are bare addresses. Re-validates after applying.
apply_network_overrides() {
    if [ -n "$IPV4_OVERRIDE" ]; then
        DETECTED_IP_ADDRESS="${IPV4_OVERRIDE%/*}"
        case "$IPV4_OVERRIDE" in
            */*) DETECTED_CIDR="${IPV4_OVERRIDE#*/}"
                 DETECTED_NETMASK=$(cidr_to_netmask "$DETECTED_CIDR") ;;
        esac
        NETWORK_IS_DHCP=false
        log_info "IPv4 override: $DETECTED_IP_ADDRESS/$DETECTED_CIDR"
    fi
    [ -n "$IPV4_GATEWAY_OVERRIDE" ] && {
        DETECTED_GATEWAY="$IPV4_GATEWAY_OVERRIDE"
        log_info "IPv4 gateway override: $DETECTED_GATEWAY"
    }
    if [ -n "$IPV6_OVERRIDE" ]; then
        DETECTED_IPV6_ADDRESS="${IPV6_OVERRIDE%/*}"
        case "$IPV6_OVERRIDE" in
            */*) DETECTED_IPV6_CIDR="${IPV6_OVERRIDE#*/}" ;;
            *)   DETECTED_IPV6_CIDR="64" ;;
        esac
        log_info "IPv6 override: $DETECTED_IPV6_ADDRESS/$DETECTED_IPV6_CIDR"
    fi
    [ -n "$IPV6_GATEWAY_OVERRIDE" ] && {
        DETECTED_IPV6_GATEWAY="$IPV6_GATEWAY_OVERRIDE"
        log_info "IPv6 gateway override: $DETECTED_IPV6_GATEWAY"
    }
    [ -n "$DNS_OVERRIDE" ] && {
        DETECTED_DNS=$(echo "$DNS_OVERRIDE" | tr ',' ' ' | xargs)
        log_info "DNS override: $DETECTED_DNS"
    }
    validate_safe_inputs
}

# Generate /etc/resolv.conf content
generate_resolv_conf() {
    for dns in $DETECTED_DNS; do
        echo "nameserver $dns"
    done
}

# Generate kernel IP parameter
generate_kernel_ip_param() {
    if [ "$NETWORK_IS_DHCP" = "true" ]; then
        echo "ip=dhcp"
    else
        # Format: ip=<client-ip>:<server-ip>:<gateway>:<netmask>:<hostname>:<device>:<autoconf>
        echo "ip=${DETECTED_IP_ADDRESS}::${DETECTED_GATEWAY}:${DETECTED_NETMASK}:${DETECTED_HOSTNAME}:${DETECTED_INTERFACE}:off"
    fi
}

# =============================================================================
# Network Configuration Summary
# =============================================================================

print_network_summary() {
    echo ""
    echo "Network Configuration Summary:"
    echo "==============================="
    echo "Interface:    $DETECTED_INTERFACE"
    echo "IP Address:   $DETECTED_IP_ADDRESS/$DETECTED_CIDR"
    echo "Netmask:      $DETECTED_NETMASK"
    echo "Gateway:      $DETECTED_GATEWAY"
    if [ -n "$DETECTED_IPV6_ADDRESS" ]; then
        echo "IPv6 Address: $DETECTED_IPV6_ADDRESS/$DETECTED_IPV6_CIDR"
        echo "IPv6 Gateway: ${DETECTED_IPV6_GATEWAY:-(none)}"
    else
        echo "IPv6 Address: (none - IPv4-only)"
    fi
    echo "DNS:          $DETECTED_DNS"
    echo "Hostname:     $DETECTED_HOSTNAME"
    echo "DHCP:         $NETWORK_IS_DHCP"
    echo "Architecture: $DETECTED_ARCH"
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        echo "Platform:     Raspberry Pi ${DETECTED_RPI_VERSION}"
    fi
    echo ""
}

# Last gate before an operation that can lose remote access (pivot / reboot
# into the RAM installer). Prints the exact network + SSH-access facts that
# must be correct to keep the box reachable, then requires confirmation.
# Bypassed by -y/--yes (ASSUME_YES, for the warren deploy script), -f/--force,
# or --dry-run. Returns non-fatally via confirm_action's die-on-no.
confirm_access_before_pivot() {
    echo "" >&2
    echo "================ ACCESS CHECK BEFORE PIVOT ================" >&2
    echo " The box is about to pivot/reboot into the installer. After" >&2
    echo " this point connectivity depends ENTIRELY on the config baked" >&2
    echo " below. Verify you can still reach it with these values:" >&2
    echo "" >&2
    echo "  Interface : $DETECTED_INTERFACE" >&2
    echo "  IPv4      : ${DETECTED_IP_ADDRESS}/${DETECTED_CIDR} gw ${DETECTED_GATEWAY} (dhcp=$NETWORK_IS_DHCP)" >&2
    if [ -n "$DETECTED_IPV6_ADDRESS" ]; then
        echo "  IPv6      : ${DETECTED_IPV6_ADDRESS}/${DETECTED_IPV6_CIDR} gw ${DETECTED_IPV6_GATEWAY:-(none)}" >&2
    else
        echo "  IPv6      : (none - IPv4-only)" >&2
    fi
    echo "  DNS       : $DETECTED_DNS" >&2
    echo "  SSH access: ${TARGET_USER:-root}@${TARGET_HOST:-localhost} port ${SSH_PORT}${SSH_KEY:+ key $SSH_KEY}" >&2
    echo "==========================================================" >&2

    if [ "$ASSUME_YES" = "true" ]; then
        log_info "Pre-pivot access check bypassed (--yes)"
        return 0
    fi
    confirm_action "Network/SSH config above is correct and reachable?"
}
