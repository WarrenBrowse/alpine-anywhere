#!/bin/bash
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
        It 'defines ESP size'
            The variable PART_ESP_SIZE should equal "256M"
        End

        It 'defines boot partition size'
            The variable PART_BOOT_SIZE should equal "512M"
        End

        It 'defines minimum disk size'
            The variable MIN_DISK_SIZE_MB should equal 1024
        End
    End
End
