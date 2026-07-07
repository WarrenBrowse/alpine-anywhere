#!/bin/sh
# network.sh - Network interface/resolv.conf generation and override handling

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
