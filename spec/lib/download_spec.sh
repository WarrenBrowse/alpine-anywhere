#!/bin/sh
# download_spec.sh - Tests for lib/download.sh

Describe 'download.sh'
    Include lib/common.sh
    Include lib/download.sh

    Describe 'build_alpine_base_url()'
        setup() {
            ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
            ALPINE_VERSION="3.20"
            DETECTED_ARCH="x86_64"
        }
        Before 'setup'

        It 'builds correct base URL for x86_64'
            When call build_alpine_base_url
            The output should equal 'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64'
        End

        Context 'with aarch64 architecture'
            setup() {
                ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
                ALPINE_VERSION="3.21"
                DETECTED_ARCH="aarch64"
            }
            Before 'setup'

            It 'builds correct base URL for aarch64'
                When call build_alpine_base_url
                The output should equal 'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64'
            End
        End

        Context 'with custom mirror'
            setup() {
                ALPINE_MIRROR="https://uk.alpinelinux.org/alpine"
                ALPINE_VERSION="3.19"
                DETECTED_ARCH="x86_64"
            }
            Before 'setup'

            It 'uses custom mirror'
                When call build_alpine_base_url
                The output should equal 'https://uk.alpinelinux.org/alpine/v3.19/releases/x86_64'
            End
        End
    End

    Describe 'build_alpine_file_url()'
        setup() {
            ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
            ALPINE_VERSION="3.20"
            DETECTED_ARCH="x86_64"
            KERNEL_FLAVOR="lts"
        }
        Before 'setup'

        It 'builds vmlinuz URL'
            When call build_alpine_file_url vmlinuz
            The output should equal 'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/vmlinuz-lts'
        End

        It 'builds initramfs URL'
            When call build_alpine_file_url initramfs
            The output should equal 'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/initramfs-lts'
        End

        It 'builds modloop URL'
            When call build_alpine_file_url modloop
            The output should equal 'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/modloop-lts'
        End

        Context 'with virt kernel flavor'
            setup() {
                ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
                ALPINE_VERSION="3.20"
                DETECTED_ARCH="x86_64"
                KERNEL_FLAVOR="virt"
            }
            Before 'setup'

            It 'builds vmlinuz URL with virt flavor'
                When call build_alpine_file_url vmlinuz
                The output should equal 'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/vmlinuz-virt'
            End
        End
    End

    Describe 'FALLBACK_MIRRORS'
        It 'contains the main CDN'
            The value "$FALLBACK_MIRRORS" should include 'https://dl-cdn.alpinelinux.org/alpine'
        End

        It 'contains at least 4 fallback mirrors'
            count() { set -- $FALLBACK_MIRRORS; echo $#; }
            The result of 'count()' should equal 4
        End
    End

    Describe 'verify_sha512() / enforce_integrity()'
        setup() {
            TESTDIR=$(mktemp -d)
            CHECKSUM_DIR="$TESTDIR"
            NO_VERIFY=false
            printf 'payload\n' > "$TESTDIR/artifact"
        }
        cleanup_dir() { rm -rf "$TESTDIR"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'verifies a matching checksum from CHECKSUM_DIR'
            write_sum() {
                sha512_file "$TESTDIR/artifact" > "$TESTDIR/artifact.sha512"
                verify_sha512 "https://example/artifact" "$TESTDIR/artifact"
            }
            When call write_sum
            The status should be success
            The stderr should include "Integrity verified"
        End

        It 'dies on a mismatching checksum'
            write_bad_sum() {
                echo "deadbeef" > "$TESTDIR/artifact.sha512"
                verify_sha512 "https://example/artifact" "$TESTDIR/artifact"
            }
            When run write_bad_sum
            The status should be failure
            The stderr should include "CHECKSUM MISMATCH"
        End

        It 'enforce_integrity is fatal when no checksum is available'
            no_sum() {
                CHECKSUM_DIR="$TESTDIR/empty"; mkdir -p "$CHECKSUM_DIR"
                # Force the HTTP fallback to yield nothing
                http_fetch_stdout() { return 1; }
                enforce_integrity "https://example/artifact" "$TESTDIR/artifact"
            }
            When run no_sum
            The status should be failure
            The stderr should include "No checksum available"
        End

        It 'enforce_integrity skips verification under --no-verify'
            skipped() {
                NO_VERIFY=true
                enforce_integrity "https://example/artifact" "$TESTDIR/artifact"
            }
            When call skipped
            The status should be success
            The stderr should include "SKIPPED"
        End
    End
End
