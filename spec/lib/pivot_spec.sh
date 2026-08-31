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

        # virtio_net was the ONLY network driver in the list, so on a physical
        # server the RAM installer had no NIC at all: the modloop carries igb,
        # nothing modprobes it, and there is no udev in there to autoload it.
        # The installer then aborts on its own mirror pre-check, before touching
        # the disk, with no way to say why.
        It 'loads physical NIC drivers so a bare-metal installer has a network'
            When call emit_and_cat
            The output should include "igb"
            The output should include "e1000e"
            The output should include "ixgbe"
        End

        # Same gap on the storage side: sd_mod alone does not bind a SATA
        # controller, and every one of these boxes boots off AHCI.
        It 'loads the SATA/RAID controller drivers, not just sd_mod'
            When call emit_and_cat
            The output should include "ahci"
        End

        # Measured on a Supermicro I210: the igb driver binds at 5.9 s and the
        # link only reaches "Up 1000 Mbps" at 15.1 s, while the init configured
        # the address and ran the installer (whose first act is a mirror
        # reachability pre-check) around 10-12 s. The check therefore failed ~9 s
        # before the NIC could carry a packet, and aborted a healthy machine.
        It 'waits for the link to carry traffic before starting the install'
            When call emit_and_cat
            The output should include "AA_LINK_WAIT"
            The output should include "carrier"
        End

        # Everything PID 1 prints must be recoverable: on a box whose console is
        # blank after kexec, an abort is otherwise indistinguishable from a hang.
        It 'captures the whole init into a log and persists it as /aa-debug.log'
            When call emit_and_cat
            The output should include "/tmp/aa-installer.log"
            The output should include "aa-debug.log"
            The output should include "set -x"
        End

        # A fifo deadlocks PID 1 at line 1 when its reader fails to start, which
        # produced no output at all: strictly worse than console-only.
        It 'never makes PID 1 block on its own logging'
            When call emit_and_cat
            The output should not include "mkfifo"
        End

        # The log lands on a disk that SURVIVES the abort, and the staged install
        # env carries an enrollment token.
        It 'redacts secret-looking assignments before writing to disk'
            When call emit_and_cat
            The output should include "REDACTED"
        End

        # Staying up forever after a failed install is only useful while dropbear
        # is reachable, and the failure that gets us here is frequently the
        # network itself. Unbounded, it turns every failure into a manual power
        # cycle; bounded, an operator still gets a rescue window and an
        # unreachable box returns to its intact source system on its own.
        It 'bounds the post-failure rescue window and reboots instead of hanging'
            When call emit_and_cat
            The output should include "AA_RESCUE_SECS"
            The output should not include "while :; do sleep 3600; done"
        End

        It 'runs the A/B install-continue from the freed disk'
            When call emit_and_cat
            The output should include "--install-continue"
        End

        # The detection host names NICs the systemd way (eno1, ens..) while this
        # RAM installer runs busybox/mdev kernel names (eth0..). Configuring the
        # baked name blind leaves the installer with no network, its mirror
        # pre-check aborts before touching the disk, and the box is unreachable
        # with nothing to say why: the installed system already guards this
        # (init_s6.sh network-up), the installer must too.
        It 'resolves the interface at runtime instead of trusting the baked name'
            When call emit_and_cat
            The output should include "/sys/class/net"
            The output should include "carrier"
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

    # KERNEL_FLAVOR defaults to lts (lib/common.sh), so an unset flavor caches
    # and returns the lts pair.
    It 'returns the cached pair without downloading'
        printf k > "$T/aa-installer-vmlinuz-lts"
        printf m > "$T/aa-installer-modloop-lts"
        When call _fetch_alpine_installer_kernel
        The status should be success
        The output should include "aa-installer-vmlinuz-lts"
        The output should include "aa-installer-modloop-lts"
    End

    It 'extracts kernel + modloop from the checksummed netboot tarball'
        KERNEL_FLAVOR=virt
        # cache_download mock materialises a tarball shaped like the mirror's.
        Mock cache_download
            mkdir -p "$T/pack/boot"
            printf kernel > "$T/pack/boot/vmlinuz-virt"
            printf modules > "$T/pack/boot/modloop-virt"
            tar -czf "$INSTALL_CACHE_DIR/$2" -C "$T/pack" boot
        End
        When call _fetch_alpine_installer_kernel
        The status should be success
        The output should include "aa-installer-vmlinuz-virt"
        The contents of file "$T/aa-installer-vmlinuz-virt" should equal "kernel"
        The contents of file "$T/aa-installer-modloop-virt" should equal "modules"
    End

    # A bare-metal target needs the drivers of its real hardware: the virt
    # modloop carries no igb and no ixgbe, so an Intel I210 box kexecs into a
    # RAM installer with no network and no way to say so.
    It 'follows KERNEL_FLAVOR so a bare-metal install gets the lts drivers'
        KERNEL_FLAVOR=lts
        Mock cache_download
            mkdir -p "$T/pack/boot"
            printf virtkernel > "$T/pack/boot/vmlinuz-virt"
            printf virtmodules > "$T/pack/boot/modloop-virt"
            printf ltskernel > "$T/pack/boot/vmlinuz-lts"
            printf ltsmodules > "$T/pack/boot/modloop-lts"
            tar -czf "$INSTALL_CACHE_DIR/$2" -C "$T/pack" boot
        End
        When call _fetch_alpine_installer_kernel
        The status should be success
        The output should include "aa-installer-vmlinuz-lts"
        The contents of file "$T/aa-installer-vmlinuz-lts" should equal "ltskernel"
        The contents of file "$T/aa-installer-modloop-lts" should equal "ltsmodules"
    End

    # The cache key carries the flavor, so a box that already cached the virt
    # pair does not silently keep booting it after the flavor changes.
    It 'ignores a cached pair of a different flavor'
        KERNEL_FLAVOR=lts
        printf k > "$T/aa-installer-vmlinuz-virt"
        printf m > "$T/aa-installer-modloop-virt"
        Mock cache_download
            mkdir -p "$T/pack/boot"
            printf ltskernel > "$T/pack/boot/vmlinuz-lts"
            printf ltsmodules > "$T/pack/boot/modloop-lts"
            tar -czf "$INSTALL_CACHE_DIR/$2" -C "$T/pack" boot
        End
        When call _fetch_alpine_installer_kernel
        The status should be success
        The output should include "aa-installer-vmlinuz-lts"
        The contents of file "$T/aa-installer-vmlinuz-lts" should equal "ltskernel"
    End
End
