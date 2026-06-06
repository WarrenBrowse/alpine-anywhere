#!/bin/bash
# Tests for upgrade.sh - A/B upgrade management

Describe 'upgrade.sh'
    Include lib/common.sh
    Include lib/upgrade.sh

    Describe 'get_inactive_slot()'
        Context 'when current slot is A'
            setup() {
                BOOT_MOUNT=$(mktemp -d)
                echo "A" > "${BOOT_MOUNT}/current_slot"
            }
            cleanup() {
                rm -rf "$BOOT_MOUNT"
            }
            Before 'setup'
            After 'cleanup'

            It 'returns B'
                When call get_inactive_slot
                The output should equal "B"
            End
        End

        Context 'when current slot is B'
            setup() {
                BOOT_MOUNT=$(mktemp -d)
                echo "B" > "${BOOT_MOUNT}/current_slot"
            }
            cleanup() {
                rm -rf "$BOOT_MOUNT"
            }
            Before 'setup'
            After 'cleanup'

            It 'returns A'
                When call get_inactive_slot
                The output should equal "A"
            End
        End
    End

    Describe 'get_current_slot()'
        Context 'when current_slot file exists'
            setup() {
                BOOT_MOUNT=$(mktemp -d)
                echo "B" > "${BOOT_MOUNT}/current_slot"
            }
            cleanup() {
                rm -rf "$BOOT_MOUNT"
            }
            Before 'setup'
            After 'cleanup'

            It 'returns the slot from file'
                When call get_current_slot
                The output should equal "B"
            End
        End

        Context 'when current_slot file does not exist'
            setup() {
                BOOT_MOUNT=$(mktemp -d)
            }
            cleanup() {
                rm -rf "$BOOT_MOUNT"
            }
            Before 'setup'
            After 'cleanup'

            It 'defaults to A'
                When call get_current_slot
                The output should equal "A"
            End
        End
    End

    Describe 'get_slot_dir()'
        setup() {
            BOOT_MOUNT="/boot"
        }
        Before 'setup'

        It 'returns correct path for slot A'
            When call get_slot_dir "A"
            The output should equal "/boot/slots/A"
        End

        It 'returns correct path for slot B'
            When call get_slot_dir "B"
            The output should equal "/boot/slots/B"
        End
    End

    Describe 'Upgrade constants'
        It 'defines max boot attempts'
            The variable MAX_BOOT_ATTEMPTS should equal 3
        End
    End
End
