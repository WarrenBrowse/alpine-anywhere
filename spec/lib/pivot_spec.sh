#!/bin/sh
# Tests for pivot.sh - Real pivot_root implementation

Describe 'pivot.sh'
    Include lib/common.sh
    Include lib/pivot.sh

    Describe 'detect_init_system()'
        # Note: This is difficult to test without mocking /proc/1/comm
        # We test the parsing logic instead

        It 'defines PIVOT_DIR constant'
            The variable PIVOT_DIR should equal "/mnt/alpine"
        End

        It 'defines OLD_ROOT constant'
            The variable OLD_ROOT should equal "/mnt/oldroot"
        End

        # Mock the PID 1 probes (cat /proc/1/comm, readlink -f /proc/1/exe).
        It 'detects s6 when PID 1 is s6-svscan'
            cat() { echo "s6-svscan"; }
            readlink() { echo "/bin/s6-svscan"; }
            When call detect_init_system
            The output should equal "s6"
        End

        It 'detects s6 when PID 1 is s6-linux-init'
            cat() { echo "s6-linux-init"; }
            readlink() { echo "/usr/bin/s6-linux-init"; }
            When call detect_init_system
            The output should equal "s6"
        End

        It 'still detects systemd'
            cat() { echo "systemd"; }
            readlink() { echo "/usr/lib/systemd/systemd"; }
            When call detect_init_system
            The output should equal "systemd"
        End
    End

    Describe 'Constants'
        It 'sets PIVOT_DIR to /mnt/alpine'
            The variable PIVOT_DIR should equal "/mnt/alpine"
        End

        It 'sets OLD_ROOT to /mnt/oldroot'
            The variable OLD_ROOT should equal "/mnt/oldroot"
        End
    End

    Describe '_pivot_takeover_or_kexec()'
        # The fix: an in-place bind-mount takeover (pivot_systemd and friends)
        # leaves PID 1 holding the boot disk, so the kernel refuses to re-read the
        # new partition table and an in-place install stalls. In INSTALL mode we
        # must instead kexec into a RAM installer (fresh kernel, disk free). In
        # LIVE mode the in-place takeover is correct (RAM-only, reverts on reboot).
        It 'kexecs into the RAM installer in install mode'
            INSTALL_MODE=true
            pivot_kexec_installer() { echo KEXEC; }
            live_takeover() { echo TAKEOVER; }
            When call _pivot_takeover_or_kexec live_takeover
            The output should equal KEXEC
        End

        It 'keeps the in-place takeover in live mode'
            INSTALL_MODE=false
            pivot_kexec_installer() { echo KEXEC; }
            live_takeover() { echo TAKEOVER; }
            When call _pivot_takeover_or_kexec live_takeover
            The output should equal TAKEOVER
        End

        It 'defaults to the in-place takeover when INSTALL_MODE is unset'
            unset INSTALL_MODE
            pivot_kexec_installer() { echo KEXEC; }
            live_takeover() { echo TAKEOVER; }
            When call _pivot_takeover_or_kexec live_takeover
            The output should equal TAKEOVER
        End
    End

    Describe '_emit_installer_init()'
        emit_and_cat() {
            run_privileged() { "$@"; }
            d=$(mktemp -d)
            _emit_installer_init "$d"
            cat "$d/init"
            rm -rf "$d"
        }

        It 'loads virtio drivers so cloud/KVM disks and NICs are visible'
            When call emit_and_cat
            The output should include "virtio_blk"
            The output should include "virtio_net"
        End

        It 'runs the A/B install-continue from the freed disk'
            When call emit_and_cat
            The output should include "--install-continue"
        End
    End

    Describe '_pack_installer_img()'
        # Regression: the pack used `set -o pipefail`, a FATAL error under dash
        # (Debian/Ubuntu /bin/sh) that aborted the whole `sh -c` before the cpio
        # pipeline ran; and it validated with `grep -qx ./init`, which GNU cpio's
        # `./`-less paths never match. Both silently broke every dash + GNU-cpio
        # host. This builds a real archive through the same code path and asserts
        # it is a valid, bootable initramfs.
        pack() {
            run_privileged() { "$@"; }
            src=$(mktemp -d)
            printf '#!/bin/sh\ntrue\n' > "$src/init"
            out=$(mktemp -u)
            if _pack_installer_img "$src" "$out" >/dev/null 2>&1; then
                gzip -dc "$out" 2>/dev/null | cpio -t 2>/dev/null \
                    | grep -qE '^(\./)?init$' && echo PACK_OK
            fi
            rm -rf "$src" "$out"
        }

        It 'builds a valid bootable initramfs (dash /bin/sh + GNU cpio safe)'
            When call pack
            The output should equal PACK_OK
        End
    End
End

Describe '_fetch_alpine_installer_kernel()'
    Include lib/common.sh
    Include lib/pivot.sh

    setup() {
        T=$(mktemp -d); INSTALL_CACHE_DIR="$T"
        # Exported: the cache_download Mock runs as an external command.
        export T INSTALL_CACHE_DIR
        DETECTED_ARCH=x86_64; ALPINE_VERSION=3.20
        ALPINE_MIRROR=https://example.invalid/alpine
    }
    cleanup_dir() { rm -rf "$T"; }
    BeforeEach 'setup'
    AfterEach 'cleanup_dir'

    It 'returns the cached pair without downloading'
        printf k > "$T/aa-installer-vmlinuz"
        printf m > "$T/aa-installer-modloop"
        When call _fetch_alpine_installer_kernel
        The status should be success
        The output should include "aa-installer-vmlinuz"
        The output should include "aa-installer-modloop"
    End

    It 'extracts kernel + modloop from the checksummed netboot tarball'
        # cache_download mock materialises a tarball shaped like the mirror's.
        Mock cache_download
            mkdir -p "$T/pack/boot"
            printf kernel > "$T/pack/boot/vmlinuz-virt"
            printf modules > "$T/pack/boot/modloop-virt"
            tar -czf "$INSTALL_CACHE_DIR/$2" -C "$T/pack" boot
        End
        When call _fetch_alpine_installer_kernel
        The status should be success
        The output should include "aa-installer-vmlinuz"
        The contents of file "$T/aa-installer-vmlinuz" should equal "kernel"
        The contents of file "$T/aa-installer-modloop" should equal "modules"
    End
End
