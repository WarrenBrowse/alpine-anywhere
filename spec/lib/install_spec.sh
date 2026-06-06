#!/bin/sh
# Tests for install.sh - A/B installation

Describe 'install.sh'
    Include lib/common.sh
    Include lib/install.sh

    Describe 'get_partition_device()'
        It 'handles standard disks (sda)'
            When call get_partition_device "/dev/sda" 1
            The output should equal "/dev/sda1"
        End

        It 'handles standard disks (sdb)'
            When call get_partition_device "/dev/sdb" 3
            The output should equal "/dev/sdb3"
        End

        It 'handles NVMe disks'
            When call get_partition_device "/dev/nvme0n1" 1
            The output should equal "/dev/nvme0n1p1"
        End

        It 'handles MMC disks (SD cards)'
            When call get_partition_device "/dev/mmcblk0" 2
            The output should equal "/dev/mmcblk0p2"
        End

        It 'handles loop devices'
            When call get_partition_device "/dev/loop0" 1
            The output should equal "/dev/loop0p1"
        End
    End

    Describe 'Partition constants'
        It 'defines boot partition size'
            The variable PART_BOOT_SIZE_MB should equal 512
        End

        It 'defines slot size'
            The variable PART_SLOT_SIZE_MB should equal 2048
        End

        It 'defines minimum disk size'
            The variable MIN_DISK_SIZE_MB should equal 5120
        End
    End

    Describe 'is_usable_data_partition()'
        It 'is defined as a function'
            The value "$(type -t is_usable_data_partition)" should equal "function"
        End

        It 'returns unformatted when fstype is empty'
            # Non-existent device returns empty fstype -> unformatted
            When call is_usable_data_partition "/dev/nonexistent999"
            The output should equal "unformatted"
            The status should be success
        End
    End

    Describe 'auto_detect_overlay_device()'
        It 'is defined as a function'
            The value "$(type -t auto_detect_overlay_device)" should equal "function"
        End
    End

    Describe 'list_available_disks()'
        It 'is defined as a function'
            The value "$(type -t list_available_disks)" should equal "function"
        End
    End

    Describe 'detect_disk_layout()'
        It 'is defined as a function'
            The value "$(type -t detect_disk_layout)" should equal "function"
        End
    End
End
