#!/bin/sh
# common.sh - Utilities, logging, and argument parsing for alpine-anywhere

set -eu

# =============================================================================
# Global Variables with Defaults
# =============================================================================

ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-lts}"
SSH_PORT="${SSH_PORT:-22}"
SSH_IDENTITY="${SSH_IDENTITY:-}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
FORCE="${FORCE:-false}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
CUSTOM_SCRIPT="${CUSTOM_SCRIPT:-}"        # User script run inside the image chroot at build
SSH_HOST_KEY_DIR="${SSH_HOST_KEY_DIR:-}"  # Control-host dir holding SSH host keys to bake in
REBOOT_DELAY="${REBOOT_DELAY:-5}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_USER="${TARGET_USER:-}"
INSTALL_METHOD="${INSTALL_METHOD:-auto}"  # auto, kexec, takeover
LOCAL_MODE="${LOCAL_MODE:-false}"         # Run locally (no SSH)
INSTALL_MODE="${INSTALL_MODE:-false}"     # Install mode (vs live mode)
INSTALL_CONTINUE="${INSTALL_CONTINUE:-false}"  # Continue installation after pivot
UPGRADE_MODE="${UPGRADE_MODE:-false}"     # Upgrade mode (A/B switch)
SLOT_ACTION="${SLOT_ACTION:-}"            # Slot subcommand: status|verify|rollback|bootcount
INIT_SYSTEM="${INIT_SYSTEM:-}"            # Init system: openrc|s6 (empty = auto: s6 if hardened else openrc)
TARGET_SLOT="${TARGET_SLOT:-}"            # Destination/boot slot: A|B (install dest; aa switch target)
KEEP_EXISTING="${KEEP_EXISTING:-false}"   # Keep existing system (dual-boot)
OVERLAY_DEVICE="${OVERLAY_DEVICE:-}"      # Device for persistent overlay
TARGET_DISK="${TARGET_DISK:-}"            # Explicit install disk (e.g. /dev/sda); empty = auto-detect
BOOT_SLOT="${BOOT_SLOT:-A}"               # Current boot slot (A/B)
HARDENED_MODE="${HARDENED_MODE:-false}"   # Security hardened mode

# Working directories (set by setup_install_dirs in exec.sh)
WORK_DIR=""
INSTALL_BASE_DIR=""
INSTALL_LIB_DIR=""
INSTALL_CACHE_DIR=""
INSTALL_LOG_DIR=""

# Detected values (populated by network.sh)
DETECTED_INTERFACE=""
DETECTED_IP_ADDRESS=""
DETECTED_NETMASK=""
DETECTED_CIDR=""
DETECTED_GATEWAY=""
DETECTED_DNS=""
DETECTED_HOSTNAME=""
DETECTED_ARCH=""
DETECTED_PLATFORM="generic"
DETECTED_RPI_VERSION=""
NETWORK_IS_DHCP=false

# =============================================================================
# Color Definitions
# =============================================================================

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$*" >&2
}

log_warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2
}

log_error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2
}

log_debug() {
    if [ "$VERBOSE" = "true" ]; then
        printf '%b[DEBUG]%b %s\n' "$BLUE" "$NC" "$*" >&2
    fi
}

log_step() {
    printf '%b==>%b %s\n' "$BOLD" "$NC" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

# =============================================================================
# Utility Functions
# =============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Create temporary working directory
create_work_dir() {
    WORK_DIR=$(mktemp -d -t alpine-anywhere.XXXXXX)
    log_debug "Created work directory: $WORK_DIR"
}

# Cleanup function called on exit
cleanup() {
    local exit_code=$?

    # Close SSH multiplexing if function exists
    if type close_ssh_multiplexing >/dev/null 2>&1; then
        close_ssh_multiplexing
    fi

    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        log_debug "Cleaning up work directory: $WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
    exit $exit_code
}

# Setup cleanup trap
setup_cleanup_trap() {
    trap cleanup EXIT INT TERM
}

# Convert CIDR prefix to netmask
cidr_to_netmask() {
    local cidr=$1
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_octet=$((cidr % 8))
    local i=0

    while [ "$i" -lt 4 ]; do
        if [ "$i" -lt "$full_octets" ]; then
            mask="${mask}255"
        elif [ "$i" -eq "$full_octets" ]; then
            mask="${mask}$((256 - (1 << (8 - partial_octet))))"
        else
            mask="${mask}0"
        fi
        if [ "$i" -lt 3 ]; then
            mask="${mask}."
        fi
        i=$((i + 1))
    done

    echo "$mask"
}

# Convert netmask to CIDR prefix
netmask_to_cidr() {
    local netmask=$1
    local cidr=0
    local IFS='.'

    for octet in $netmask; do
        case $octet in
            255) cidr=$((cidr + 8)) ;;
            254) cidr=$((cidr + 7)) ;;
            252) cidr=$((cidr + 6)) ;;
            248) cidr=$((cidr + 5)) ;;
            240) cidr=$((cidr + 4)) ;;
            224) cidr=$((cidr + 3)) ;;
            192) cidr=$((cidr + 2)) ;;
            128) cidr=$((cidr + 1)) ;;
            0)   ;;
            *)   die "Invalid netmask octet: $octet" ;;
        esac
    done

    echo "$cidr"
}

# Validate IP address format
is_valid_ip() {
    local ip=$1
    local oIFS="$IFS"
    local count=0
    local octet

    IFS='.'
    for octet in $ip; do
        count=$((count + 1))
    done
    IFS="$oIFS"

    [ "$count" -eq 4 ] || return 1

    IFS='.'
    for octet in $ip; do
        # Check that octet is numeric
        case "$octet" in
            ''|*[!0-9]*) IFS="$oIFS"; return 1 ;;
        esac
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            IFS="$oIFS"
            return 1
        fi
    done
    IFS="$oIFS"

    return 0
}

# Parse user@host string
parse_target() {
    local target=$1

    case "$target" in
        *@*)
            TARGET_USER="${target%%@*}"
            TARGET_HOST="${target#*@}"
            ;;
        *)
            TARGET_USER="root"
            TARGET_HOST="$target"
            ;;
    esac

    log_debug "Target user: $TARGET_USER, host: $TARGET_HOST"
}

# =============================================================================
# Argument Parsing
# =============================================================================

show_usage() {
    cat <<EOF
Usage: alpine-anywhere [OPTIONS] [user@host]
       alpine-anywhere upgrade [OPTIONS] [user@host]

Boot any Linux server into Alpine Linux (immutable, RAM-only, A/B updates).

Arguments:
  user@host                      Target server (omit for --local mode)

Modes:
  (default)                      Live mode - boot Alpine in RAM, revert on reboot
  --install                      Install mode - install Alpine permanently (A/B scheme)
  upgrade                        Upgrade to new version (atomic A/B switch)

A/B slot subcommands (run on an installed device; omit host to act locally):
  status                         Show active slot and per-slot metadata
  verify                         Mark the running slot as known-good (stops auto-rollback)
  rollback                       Switch back to the other slot and reboot
  switch A|B                     Set the boot slot (reboot to activate)

Options:
  -V, --alpine-version VERSION   Alpine version (default: 3.20)
  -m, --mirror URL               Alpine mirror URL
  -k, --kernel FLAVOR            Kernel flavor: lts or virt (default: lts)
  -p, --port PORT                SSH port (default: 22)
  -i, --identity FILE            SSH private key file
  -n, --dry-run                  Show what would be done without executing
  -v, --verbose                  Verbose output
  -f, --force                    Skip confirmation prompts
  --local                        Run locally (no SSH, for running on target server)
  --method METHOD                Live mode method: auto, kexec, takeover (default: auto)
  --extra-packages PKGS          Additional packages (comma-separated)
  -h, --help                     Show this help message

Install options:
  --keep                         Keep existing system (dual-boot)
  --slot A|B                     Destination slot (default A). --slot B installs into the
                                   second slot of an existing layout without touching slot A.
  --disk DEVICE                  Target install disk (e.g. /dev/sda). REQUIRED when more
                                   than one disk is present (e.g. SD + USB) - the installer
                                   refuses to guess and risk wiping the boot medium.
  --overlay DEVICE               Device/partition for persistent data overlay

Image customization:
  --extra-packages PKGS          Additional apk packages (comma-separated)
  --custom-script FILE           Shell script run inside the image chroot at build
                                   time (network available). Use to install extra
                                   software or fetch a project, e.g.:
                                     wget -O- https://github.com/aya/myos/...tar.gz \\
                                       | tar -xz -C /usr/local/share
  --ssh-host-keys DIR            Bake these SSH host keys into the image (control-host
                                   override). Default: reuse the keys already in use on
                                   the building system so identity is stable across A/B.

Init system:
  --init SYSTEM                  Init/service manager: openrc or s6
                                   (default: s6 in --hardened mode, else openrc)

Security options:
  --hardened                     Security hardened mode:
                                   - linux-hardened kernel (KSPP)
                                   - dropbear instead of openssh
                                   - hardened_malloc
                                   - Network stack hardening (sysctl)
                                   - Kernel lockdown mode
                                   - nftables firewall

Examples:
  # Live mode - temporary Alpine boot (reverts on reboot)
  alpine-anywhere root@192.168.1.100
  alpine-anywhere --method=takeover q@raspberry-pi

  # Install mode - permanent immutable Alpine with A/B updates
  alpine-anywhere --install root@192.168.1.100
  alpine-anywhere --install --overlay /dev/sda3 root@server

  # Upgrade existing installation (atomic A/B switch)
  alpine-anywhere upgrade root@192.168.1.100

  # Local installation (run directly on target server)
  alpine-anywhere --local --install

EOF
}

parse_arguments() {
    local pos_count=0
    local pos_0=""
    local pos_1=""

    while [ $# -gt 0 ]; do
        case $1 in
            -V|--alpine-version)
                ALPINE_VERSION="$2"
                shift 2
                ;;
            -m|--mirror)
                ALPINE_MIRROR="$2"
                shift 2
                ;;
            -k|--kernel)
                KERNEL_FLAVOR="$2"
                if [ "$KERNEL_FLAVOR" != "lts" ] && [ "$KERNEL_FLAVOR" != "virt" ]; then
                    die "Invalid kernel flavor: $KERNEL_FLAVOR (must be 'lts' or 'virt')"
                fi
                shift 2
                ;;
            -p|--port)
                SSH_PORT="$2"
                shift 2
                ;;
            -i|--identity)
                SSH_IDENTITY="$2"
                if [ ! -f "$SSH_IDENTITY" ]; then
                    die "SSH identity file not found: $SSH_IDENTITY"
                fi
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            --local)
                LOCAL_MODE=true
                shift
                ;;
            --extra-packages)
                EXTRA_PACKAGES="$2"
                shift 2
                ;;
            --extra-packages=*)
                EXTRA_PACKAGES="${1#*=}"
                shift
                ;;
            --custom-script)
                CUSTOM_SCRIPT="$2"
                shift 2
                ;;
            --custom-script=*)
                CUSTOM_SCRIPT="${1#*=}"
                shift
                ;;
            --ssh-host-keys)
                SSH_HOST_KEY_DIR="$2"
                shift 2
                ;;
            --ssh-host-keys=*)
                SSH_HOST_KEY_DIR="${1#*=}"
                shift
                ;;
            --method)
                INSTALL_METHOD="$2"
                if [ "$INSTALL_METHOD" != "auto" ] && [ "$INSTALL_METHOD" != "kexec" ] && [ "$INSTALL_METHOD" != "takeover" ]; then
                    die "Invalid method: $INSTALL_METHOD (must be 'auto', 'kexec', or 'takeover')"
                fi
                shift 2
                ;;
            --method=*)
                INSTALL_METHOD="${1#*=}"
                if [ "$INSTALL_METHOD" != "auto" ] && [ "$INSTALL_METHOD" != "kexec" ] && [ "$INSTALL_METHOD" != "takeover" ]; then
                    die "Invalid method: $INSTALL_METHOD (must be 'auto', 'kexec', or 'takeover')"
                fi
                shift
                ;;
            --reboot-delay)
                REBOOT_DELAY="$2"
                shift 2
                ;;
            --install)
                INSTALL_MODE=true
                shift
                ;;
            --install-continue)
                INSTALL_CONTINUE=true
                INSTALL_MODE=true
                LOCAL_MODE=true
                shift
                ;;
            --keep)
                KEEP_EXISTING=true
                shift
                ;;
            --overlay)
                OVERLAY_DEVICE="$2"
                shift 2
                ;;
            --overlay=*)
                OVERLAY_DEVICE="${1#*=}"
                shift
                ;;
            --disk)
                TARGET_DISK="$2"
                shift 2
                ;;
            --disk=*)
                TARGET_DISK="${1#*=}"
                shift
                ;;
            upgrade)
                UPGRADE_MODE=true
                shift
                ;;
            status|verify|rollback|bootcount|switch)
                SLOT_ACTION="$1"
                shift
                ;;
            --slot)
                TARGET_SLOT="$2"
                shift 2
                ;;
            --slot=*)
                TARGET_SLOT="${1#*=}"
                shift
                ;;
            --hardened)
                HARDENED_MODE=true
                shift
                ;;
            --init)
                INIT_SYSTEM="$2"
                shift 2
                ;;
            --init=*)
                INIT_SYSTEM="${1#*=}"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [ "$pos_count" -eq 0 ]; then
                    pos_0="$1"
                elif [ "$pos_count" -eq 1 ]; then
                    pos_1="$1"
                fi
                pos_count=$((pos_count + 1))
                shift
                ;;
        esac
    done

    # `aa switch <A|B>`: the positional is the target slot, run locally.
    if [ "$SLOT_ACTION" = "switch" ]; then
        [ -n "$pos_0" ] && TARGET_SLOT="$pos_0"
        LOCAL_MODE=true
        TARGET_USER="root"
        TARGET_HOST="localhost"
        return 0
    fi

    if [ "$pos_count" -eq 0 ]; then
        if [ -n "$SLOT_ACTION" ]; then
            # Slot subcommands with no target run locally on the installed device
            LOCAL_MODE=true
        elif [ "$LOCAL_MODE" != "true" ]; then
            show_usage
            die "Missing target host (use --local for local installation)"
        fi
        # Local mode - target is localhost
        TARGET_USER="root"
        TARGET_HOST="localhost"
    elif [ "$pos_count" -eq 1 ]; then
        parse_target "$pos_0"
    else
        die "Too many arguments"
    fi
}

# =============================================================================
# Confirmation
# =============================================================================

confirm_action() {
    local message=$1

    if [ "$FORCE" = "true" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        return 0
    fi

    printf '%bWARNING:%b %s\n' "$YELLOW" "$NC" "$message" >&2
    printf 'Continue? [y/N] ' >&2
    read -r response

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            die "Aborted by user"
            ;;
    esac
}
