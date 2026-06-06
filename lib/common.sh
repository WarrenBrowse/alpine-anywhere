#!/bin/bash
# common.sh - Utilities, logging, and argument parsing for alpine-anywhere

set -euo pipefail

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
REBOOT_DELAY="${REBOOT_DELAY:-5}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_USER="${TARGET_USER:-}"
INSTALL_METHOD="${INSTALL_METHOD:-auto}"  # auto, kexec, takeover
LOCAL_MODE="${LOCAL_MODE:-false}"         # Run locally (no SSH)
INSTALL_MODE="${INSTALL_MODE:-false}"     # Install mode (vs live mode)
UPGRADE_MODE="${UPGRADE_MODE:-false}"     # Upgrade mode (A/B switch)
KEEP_EXISTING="${KEEP_EXISTING:-false}"   # Keep existing system (dual-boot)
OVERLAY_DEVICE="${OVERLAY_DEVICE:-}"      # Device for persistent overlay
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

if [[ -t 1 ]]; then
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
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

log_step() {
    echo -e "${BOLD}==>${NC} $*" >&2
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
    if type close_ssh_multiplexing &>/dev/null; then
        close_ssh_multiplexing
    fi

    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
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

    for ((i = 0; i < 4; i++)); do
        if ((i < full_octets)); then
            mask+="255"
        elif ((i == full_octets)); then
            mask+="$((256 - (1 << (8 - partial_octet))))"
        else
            mask+="0"
        fi
        if ((i < 3)); then
            mask+="."
        fi
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
    local IFS='.'
    local -a octets

    read -ra octets <<< "$ip"

    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((octet >= 0 && octet <= 255)) || return 1
    done

    return 0
}

# Parse user@host string
parse_target() {
    local target=$1

    if [[ "$target" =~ ^([^@]+)@(.+)$ ]]; then
        TARGET_USER="${BASH_REMATCH[1]}"
        TARGET_HOST="${BASH_REMATCH[2]}"
    else
        TARGET_USER="root"
        TARGET_HOST="$target"
    fi

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
  --overlay DEVICE               Device/partition for persistent data overlay

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
    local positional=()

    while [[ $# -gt 0 ]]; do
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
                if [[ "$KERNEL_FLAVOR" != "lts" && "$KERNEL_FLAVOR" != "virt" ]]; then
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
                if [[ ! -f "$SSH_IDENTITY" ]]; then
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
            --method)
                INSTALL_METHOD="$2"
                if [[ "$INSTALL_METHOD" != "auto" && "$INSTALL_METHOD" != "kexec" && "$INSTALL_METHOD" != "takeover" ]]; then
                    die "Invalid method: $INSTALL_METHOD (must be 'auto', 'kexec', or 'takeover')"
                fi
                shift 2
                ;;
            --method=*)
                INSTALL_METHOD="${1#*=}"
                if [[ "$INSTALL_METHOD" != "auto" && "$INSTALL_METHOD" != "kexec" && "$INSTALL_METHOD" != "takeover" ]]; then
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
            upgrade)
                UPGRADE_MODE=true
                shift
                ;;
            --hardened)
                HARDENED_MODE=true
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
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -eq 0 ]]; then
        if [[ "$LOCAL_MODE" != "true" ]]; then
            show_usage
            die "Missing target host (use --local for local installation)"
        fi
        # Local mode - target is localhost
        TARGET_USER="root"
        TARGET_HOST="localhost"
    elif [[ ${#positional[@]} -eq 1 ]]; then
        parse_target "${positional[0]}"
    else
        die "Too many arguments"
    fi
}

# =============================================================================
# Confirmation
# =============================================================================

confirm_action() {
    local message=$1

    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    echo -e "${YELLOW}WARNING:${NC} $message" >&2
    echo -n "Continue? [y/N] " >&2
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
