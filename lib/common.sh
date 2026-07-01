#!/bin/sh
# common.sh - Utilities, logging, and argument parsing for alpine-anywhere

set -eu

# =============================================================================
# Global Variables with Defaults
# =============================================================================

ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-lts}"
KERNEL_PKG="${KERNEL_PKG:-}"              # Override the install kernel apk (e.g. linux-lts, linux-edge, a custom linux-hardened); empty = auto by platform
SSH_PORT="${SSH_PORT:-22}"
SSH_IDENTITY="${SSH_IDENTITY:-}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-}"    # Pinned known_hosts file (enforces StrictHostKeyChecking=yes)
SSH_FINGERPRINT="${SSH_FINGERPRINT:-}"    # Expected host-key fingerprint (out-of-band pin)
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
FORCE="${FORCE:-false}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
CUSTOM_SCRIPT="${CUSTOM_SCRIPT:-}"        # User script run inside the image chroot at build
CUSTOM_FILES="${CUSTOM_FILES:-}"          # File or dir staged into the chroot ($AA_CUSTOM_FILES_DIR) for the custom script
SSH_HOST_KEY_DIR="${SSH_HOST_KEY_DIR:-}"  # Control-host dir holding SSH host keys to bake in
# Network override/add inputs (empty = use the live-detected value as-is).
# Each accepts ADDR/PREFIX; gateways are bare addresses. IPv6 overrides let
# you ADD v6 to a v4-only host (e.g. an FDC box given a static /64) without
# any v6 on the source system. See apply_network_overrides().
IPV4_OVERRIDE="${IPV4_OVERRIDE:-}"            # e.g. 203.0.113.5/29 (overrides detected v4 addr/prefix)
IPV4_GATEWAY_OVERRIDE="${IPV4_GATEWAY_OVERRIDE:-}"
IPV6_OVERRIDE="${IPV6_OVERRIDE:-}"            # e.g. 2001:db8::2/64 (adds/overrides v6 addr/prefix)
IPV6_GATEWAY_OVERRIDE="${IPV6_GATEWAY_OVERRIDE:-}"
DNS_OVERRIDE="${DNS_OVERRIDE:-}"              # space/comma-separated resolvers
ASSUME_YES="${ASSUME_YES:-false}"             # bypass the pre-pivot access-confirmation step (non-interactive deploy)
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
NO_VERIFY="${NO_VERIFY:-false}"           # Skip artifact checksum verification (UNSAFE)
CHECKSUM_DIR="${CHECKSUM_DIR:-}"          # Local dir of *.sha512 files (air-gapped mirror)
VERITY_MODE="${VERITY_MODE:-auto}"        # dm-verity on slots: auto|on|off (auto = on iff hardened)

# Data persistence (immutable A/B root stays RAM; only the data partition persists)
PERSIST_DATA="${PERSIST_DATA:-false}"     # Persist /var (+ /srv /home) on the data partition (sda4)
DATA_FS="${DATA_FS:-btrfs}"               # Data partition filesystem: btrfs|ext4 (btrfs = snapshots)
ENCRYPT_DATA="${ENCRYPT_DATA:-false}"     # LUKS-encrypt the data partition
UNLOCK_METHOD="${UNLOCK_METHOD:-ssh}"     # LUKS unlock: ssh|keyfile|passphrase (ssh = manual aa-unlock, no key at rest)
KEY_URL="${KEY_URL:-}"                     # keyfile method: URL to fetch the LUKS key (mTLS)
KEY_FILE="${KEY_FILE:-}"                   # keyfile method: local key file baked to boot FAT
CONTAINERS="${CONTAINERS:-none}"          # Container runtime baked in: none|podman|docker|both (podman = rootless)
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-crun}"  # OCI runtime: crun|runsc (runsc = gVisor, fetched in custom-script)
# --hostname: operator-chosen hostname baked into /etc/hostname. Empty = fall
# back to the detected hostname of the source system (which is usually stale for
# a re-provisioned box, e.g. the old provider default).
HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-}"

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
DETECTED_IPV6_ADDRESS=""
DETECTED_IPV6_CIDR=""
DETECTED_IPV6_GATEWAY=""
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

# True if PATH is a block device. Wrapped in a function so tests can stub it
# (they can't create real block devices without root).
is_block_device() {
    [ -b "$1" ]
}

# Ensure the system clock is sane before any TLS download. RTC-less hardware
# (e.g. a Raspberry Pi) can boot at ~1970, which makes every HTTPS certificate
# look "not yet valid" and breaks fail-closed integrity checks. Best-effort:
# if the year looks bogus, try to step the clock via NTP (busybox ntpd, then
# chronyd/ntpd if present). Never fatal - just warns if it can't fix it.
ensure_sane_clock() {
    _esc_year=$(date -u +%Y 2>/dev/null || echo 1970)
    [ "${_esc_year:-1970}" -ge 2021 ] 2>/dev/null && return 0

    log_warn "System clock looks wrong (year ${_esc_year}); syncing time before TLS downloads..."
    _esc_pool="pool.ntp.org"
    if command_exists ntpd; then
        # busybox ntpd: -q quit after sync, -n no daemon, -p server
        ntpd -q -n -p "$_esc_pool" >/dev/null 2>&1 \
            || ntpd -dnq -p "$_esc_pool" >/dev/null 2>&1 || true
    fi
    _esc_year=$(date -u +%Y 2>/dev/null || echo 1970)
    if [ "${_esc_year:-1970}" -lt 2021 ] 2>/dev/null && command_exists chronyd; then
        chronyd -q "server $_esc_pool iburst" >/dev/null 2>&1 || true
        _esc_year=$(date -u +%Y 2>/dev/null || echo 1970)
    fi

    if [ "${_esc_year:-1970}" -ge 2021 ] 2>/dev/null; then
        log_info "Clock synced: $(date -u 2>/dev/null)"
    else
        log_warn "Could not sync clock automatically. HTTPS/integrity checks may fail."
        log_warn "Fix manually (e.g. 'date -s \"YYYY-MM-DD HH:MM:SS\"') and retry."
    fi
}

# Install one or more build-host packages with whatever package manager the
# builder has (Alpine apk / Debian apt / Arch+SystemRescue pacman / RHEL dnf|yum).
# aa is meant to run on ANY Linux host, so builder-side deps must not assume apk.
# Best-effort: package names are assumed identical across managers (true for
# cryptsetup, btrfs-progs, syslinux, ...); logs and continues on failure so the
# caller's own `command -v` check stays the authority.
ensure_host_pkg() {
    [ "$#" -gt 0 ] || return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@" >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$@" >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "$@" >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@" >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@" >/dev/null 2>&1 || true
    else
        log_warn "no known package manager (apk/apt/pacman/dnf/yum); cannot install: $*"
    fi
}

# Data-persistence predicates.
persist_enabled() { [ "$PERSIST_DATA" = "true" ]; }
encrypt_enabled() { [ "$ENCRYPT_DATA" = "true" ]; }
containers_enabled() { [ "$CONTAINERS" != "none" ] && [ -n "$CONTAINERS" ]; }
# True if the chosen container set includes a given runtime (podman|docker).
container_is() {
    case "$CONTAINERS" in
        both) return 0 ;;
        "$1") return 0 ;;
        *) return 1 ;;
    esac
}

# Is dm-verity protection of the A/B slots enabled? auto => on iff --hardened.
verity_enabled() {
    case "$VERITY_MODE" in
        on) return 0 ;;
        off) return 1 ;;
        auto) [ "$HARDENED_MODE" = "true" ] ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Error-handling discipline
# =============================================================================
#
# `set -eu` is global (top of this file) but MUST NOT be relied upon for any
# command that mutates persistent state: in a conditional context (inside
# `if`, `&&`, `||`, or a function whose result is tested) `set -e` is
# suppressed, so a failing mount/dd/mkfs would silently continue. Every such
# command goes through `require` (abort on failure) or `try_warn` (best-effort,
# returns status). Never use `set -e` in PID 1 / init contexts (a failing probe
# must not kill init) - those use explicit per-step checks instead.

# Run a command; abort with context if it fails. Use for every stateful op
# (mount, umount, mkfs, parted, losetup, dd, cp of boot files, ...).
require() {
    "$@" || die "command failed (exit $?): $*"
}

# Run a best-effort command; log a warning on failure but keep going.
# Returns the command's exit status. Use for genuinely optional steps
# (partprobe, cosmetic cleanup) - replaces silent `|| true`.
try_warn() {
    if "$@"; then
        return 0
    else
        _tw_rc=$?
        log_warn "non-fatal command failed (exit $_tw_rc): $*"
        return "$_tw_rc"
    fi
}

# Quote a single value so it is safe to embed in a remote shell command line.
# POSIX sh / BusyBox ash / bash 3.2 compatible. Each ' becomes '\'' .
# NOTE: command substitution strips trailing newlines, so this helper must
# only be used for short scalar values (hostnames, paths, versions), never for
# multi-line file content - transfer file content with scp_to_remote instead.
shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Portable SHA-512 of a file -> bare hex on stdout (no filename).
# Tries sha512sum (Linux/BusyBox), shasum (macOS), then openssl.
sha512_file() {
    if command_exists sha512sum; then
        sha512sum "$1" | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 512 "$1" | awk '{print $1}'
    elif command_exists openssl; then
        openssl dgst -sha512 "$1" | awk '{print $NF}'
    else
        die "no SHA-512 tool available (need sha512sum, shasum, or openssl)"
    fi
}

# Portable SHA-256 of a file -> bare hex on stdout (no filename).
sha256_file() {
    if command_exists sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command_exists openssl; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        die "no SHA-256 tool available (need sha256sum, shasum, or openssl)"
    fi
}

# Atomically replace FILE with stdin: write to a temp sibling, fsync, rename,
# then sync the directory. Survives power loss without leaving a truncated
# file. Use for slots.meta, current_slot, config.txt/cmdline.txt/extlinux.conf.
atomic_write() {
    _aw_file="$1"
    _aw_tmp="${_aw_file}.aatmp.$$"
    cat > "$_aw_tmp" || { rm -f "$_aw_tmp"; die "atomic_write: cannot write $_aw_tmp"; }
    sync "$_aw_tmp" 2>/dev/null || sync
    mv -f "$_aw_tmp" "$_aw_file" || { rm -f "$_aw_tmp"; die "atomic_write: cannot rename to $_aw_file"; }
    # Sync parent dir so the rename itself is durable (best-effort: busybox
    # sync has no -d, so fall back to a global sync).
    sync "$(dirname "$_aw_file")" 2>/dev/null || sync
}

# Assert that DIR is currently a mount point. Closes the "wrote to the tmpfs
# mountpoint because mount silently failed, install reported success but the
# system is unbootable" hole. PROC_MOUNTS is overridable for tests.
assert_mounted() {
    _am_dir="$1"
    _am_proc="${PROC_MOUNTS:-/proc/mounts}"
    if command_exists mountpoint; then
        mountpoint -q "$_am_dir" && return 0
    fi
    grep -q " $_am_dir " "$_am_proc" 2>/dev/null || die "expected $_am_dir to be a mount point, but it is not (mount failed?)"
}

# Write a disk image to a block device, durably and verified.
#   - conv=fsync so the data is on the platter before we return
#   - stderr is surfaced (not discarded) so a write error is visible
#   - read back and compare SHA-256 to catch partial writes / bad media before
#     the slot is ever marked bootable
# Echoes the image's sha256 on success (callers store it in slots.meta).
write_image_to_device() {
    _wid_src="$1"; _wid_dev="$2"
    [ -f "$_wid_src" ] || die "write_image_to_device: source $_wid_src missing"
    is_block_device "$_wid_dev" || die "write_image_to_device: $_wid_dev is not a block device"

    require dd if="$_wid_src" of="$_wid_dev" bs=1M conv=fsync
    sync

    _wid_size=$(wc -c < "$_wid_src")
    _wid_want=$(sha256_file "$_wid_src")
    # Read back exactly as many bytes as the image and hash them.
    _wid_got=$(dd if="$_wid_dev" bs=1M 2>/dev/null | head -c "$_wid_size" | { \
        if command_exists sha256sum; then sha256sum | awk '{print $1}';
        elif command_exists shasum; then shasum -a 256 | awk '{print $1}';
        else openssl dgst -sha256 | awk '{print $NF}'; fi; })
    if [ "$_wid_want" != "$_wid_got" ]; then
        die "write_image_to_device: read-back mismatch on $_wid_dev (image not durably/correctly written)"
    fi
    log_info "Image write verified (sha256) on $_wid_dev"
    echo "$_wid_want"
}

# In-place sed with verification. Runs `sed -e EXPR... FILE` to a temp file,
# requires the result to be non-empty AND to contain EXPECT (the post-edit
# state the caller expects), then atomically replaces FILE. Dies on a
# zero-match no-op - silently failing to flip a slot is a brick path after an
# upgrade. Usage: sed_inplace_checked FILE EXPECT -e 's|...|...|' [-e ...]
sed_inplace_checked() {
    _sic_file="$1"; _sic_expect="$2"; shift 2
    _sic_tmp="${_sic_file}.aatmp.$$"
    sed "$@" "$_sic_file" > "$_sic_tmp" || { rm -f "$_sic_tmp"; die "sed_inplace_checked: sed failed on $_sic_file"; }
    [ -s "$_sic_tmp" ] || { rm -f "$_sic_tmp"; die "sed_inplace_checked: result empty for $_sic_file"; }
    if ! grep -q "$_sic_expect" "$_sic_tmp"; then
        rm -f "$_sic_tmp"
        die "sed_inplace_checked: expected state '$_sic_expect' absent after edit of $_sic_file"
    fi
    mv -f "$_sic_tmp" "$_sic_file" || { rm -f "$_sic_tmp"; die "sed_inplace_checked: cannot replace $_sic_file"; }
    sync "$_sic_file" 2>/dev/null || sync
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
        secure_wipe_dir "$WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
    exit $exit_code
}

# Best-effort secure erase of sensitive material (SSH host keys, apkovl,
# captured keys) under a directory before it is removed. Uses shred when
# available, else overwrites with a single zero pass. Never fatal.
secure_wipe_dir() {
    _swd_dir="$1"
    [ -d "$_swd_dir" ] || return 0
    if command_exists shred; then
        find "$_swd_dir" -type f \( -name '*_key' -o -name '*.tar.gz' -o -name 'authorized_keys' -o -path '*ssh*' \) \
            -exec shred -u {} + 2>/dev/null || true
    else
        find "$_swd_dir" -type f \( -name '*_key' -o -name '*.tar.gz' -o -name 'authorized_keys' -o -path '*ssh*' \) \
            -exec sh -c 'dd if=/dev/zero of="$1" bs=1k count=8 conv=notrunc 2>/dev/null; rm -f "$1"' _ {} \; 2>/dev/null || true
    fi
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
  --kernel-pkg PKG               Override the install kernel apk package
                                   (default: linux-rpi on Pi, else linux-lts).
                                   Use to enable dm-verity on a Pi (linux-lts/
                                   linux-edge have CONFIG_DM_VERITY; linux-rpi
                                   does not), or to install a custom hardened
                                   kernel published in your own apk repo.
  -p, --port PORT                SSH port (default: 22)
  -i, --identity FILE            SSH private key file
  --known-hosts FILE             Pin the target's host key via this known_hosts
                                   file (enforces StrictHostKeyChecking=yes)
  --ssh-fingerprint FP           Expected host-key fingerprint; abort on mismatch
                                   (out-of-band MITM defence)
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
  --custom-files PATH            File or directory staged into the chroot and exposed
                                   to --custom-script via \$AA_CUSTOM_FILES_DIR (e.g. a
                                   pre-built binary to install without network at build)
  --ssh-host-keys DIR            Bake these SSH host keys into the image (control-host
                                   override). Default: reuse the keys already in use on
                                   the building system so identity is stable across A/B.

Network (defaults: captured live from the running kernel - the REAL active
config, whatever set it: systemd, openrc, s6, or a manual ip command):
  --ipv4 ADDR/PREFIX             Override the detected IPv4 (e.g. 203.0.113.5/29)
  --ipv4-gateway ADDR            Override the detected IPv4 gateway
  --ipv6 ADDR/PREFIX             Add or override IPv6 (e.g. 2001:db8::2/64). Lets
                                   you give v6 to a v4-only host (FDC static /64)
  --ipv6-gateway ADDR            IPv6 gateway (e.g. 2001:db8::1)
  --dns "S1 S2"                  Override resolvers (space/comma-separated)
  --hostname NAME                Hostname baked into the installed system
                                   (default: reuse the source system's hostname)
  -y, --yes                      Skip the pre-pivot access confirmation (for the
                                   warren deploy script / non-interactive runs)

Init system:
  --init SYSTEM                  Init/service manager: openrc or s6
                                   (default: s6 in --hardened mode, else openrc)

Integrity options:
  --checksum-dir DIR             Verify downloads against local *.sha512 files
                                   in DIR (for air-gapped/pinned mirrors)
  --no-verify                    Skip artifact checksum verification (UNSAFE -
                                   only for debugging; never for a VPN host)
  --verity                       Protect A/B root slots with dm-verity (default
                                   ON in --hardened): per-slot hash tree, root
                                   verified block-by-block at boot
  --no-verity                    Disable dm-verity (debug / unsupported kernels)

Data persistence options (immutable A/B root stays RAM; only data persists):
  --persist                      Persist /var (+ /srv /home) on the data partition
                                   (sda4). Survives reboots and A/B upgrades.
  --data-fs btrfs|ext4           Data filesystem (default btrfs: snapshots/backups)
  --encrypt-data                 LUKS-encrypt the data partition (implies --persist)
  --unlock-method ssh|keyfile|passphrase
                                   How the encrypted data is unlocked (default ssh:
                                   manual `aa-unlock` after boot, no key at rest;
                                   the OS still boots & is reachable while locked)
  --key-url URL                  keyfile method: fetch the LUKS key from URL (mTLS)
  --key-file FILE                keyfile method: bake a local key onto the boot FAT
  --containers podman|docker|both
                                   Bake a container runtime, data on the persistent
                                   volume (default none; podman = rootless)
  --container-runtime crun|runsc  OCI runtime (runsc = gVisor, fetched at build)

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
            --custom-files)
                CUSTOM_FILES="$2"
                shift 2
                ;;
            --custom-files=*)
                CUSTOM_FILES="${1#*=}"
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
            --hostname)
                HOSTNAME_OVERRIDE="$2"
                shift 2
                ;;
            --hostname=*)
                HOSTNAME_OVERRIDE="${1#*=}"
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
            --no-verify)
                NO_VERIFY=true
                shift
                ;;
            --known-hosts)
                SSH_KNOWN_HOSTS="$2"
                shift 2
                ;;
            --known-hosts=*)
                SSH_KNOWN_HOSTS="${1#*=}"
                shift
                ;;
            --ssh-fingerprint)
                SSH_FINGERPRINT="$2"
                shift 2
                ;;
            --ssh-fingerprint=*)
                SSH_FINGERPRINT="${1#*=}"
                shift
                ;;
            --kernel-pkg)
                KERNEL_PKG="$2"
                shift 2
                ;;
            --kernel-pkg=*)
                KERNEL_PKG="${1#*=}"
                shift
                ;;
            --verity)
                VERITY_MODE=on
                shift
                ;;
            --no-verity)
                VERITY_MODE=off
                shift
                ;;
            --persist)
                PERSIST_DATA=true
                shift
                ;;
            --data-fs)
                DATA_FS="$2"
                shift 2
                ;;
            --data-fs=*)
                DATA_FS="${1#*=}"
                shift
                ;;
            --encrypt-data)
                ENCRYPT_DATA=true
                PERSIST_DATA=true
                shift
                ;;
            --unlock-method)
                UNLOCK_METHOD="$2"
                shift 2
                ;;
            --unlock-method=*)
                UNLOCK_METHOD="${1#*=}"
                shift
                ;;
            --key-url)
                KEY_URL="$2"; UNLOCK_METHOD=keyfile
                shift 2
                ;;
            --key-url=*)
                KEY_URL="${1#*=}"; UNLOCK_METHOD=keyfile
                shift
                ;;
            --key-file)
                KEY_FILE="$2"; UNLOCK_METHOD=keyfile
                shift 2
                ;;
            --key-file=*)
                KEY_FILE="${1#*=}"; UNLOCK_METHOD=keyfile
                shift
                ;;
            --containers)
                CONTAINERS="$2"; PERSIST_DATA=true
                shift 2
                ;;
            --containers=*)
                CONTAINERS="${1#*=}"; PERSIST_DATA=true
                shift
                ;;
            --container-runtime)
                CONTAINER_RUNTIME="$2"
                shift 2
                ;;
            --container-runtime=*)
                CONTAINER_RUNTIME="${1#*=}"
                shift
                ;;
            --checksum-dir)
                CHECKSUM_DIR="$2"
                shift 2
                ;;
            --checksum-dir=*)
                CHECKSUM_DIR="${1#*=}"
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
            --ipv4)
                IPV4_OVERRIDE="$2"; shift 2 ;;
            --ipv4=*)
                IPV4_OVERRIDE="${1#*=}"; shift ;;
            --ipv4-gateway)
                IPV4_GATEWAY_OVERRIDE="$2"; shift 2 ;;
            --ipv4-gateway=*)
                IPV4_GATEWAY_OVERRIDE="${1#*=}"; shift ;;
            --ipv6)
                IPV6_OVERRIDE="$2"; shift 2 ;;
            --ipv6=*)
                IPV6_OVERRIDE="${1#*=}"; shift ;;
            --ipv6-gateway)
                IPV6_GATEWAY_OVERRIDE="$2"; shift 2 ;;
            --ipv6-gateway=*)
                IPV6_GATEWAY_OVERRIDE="${1#*=}"; shift ;;
            --dns)
                DNS_OVERRIDE="$2"; shift 2 ;;
            --dns=*)
                DNS_OVERRIDE="${1#*=}"; shift ;;
            -y|--yes|--assume-yes)
                ASSUME_YES=true; shift ;;
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
