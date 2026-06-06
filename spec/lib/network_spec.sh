#!/bin/bash
# network_spec.sh - Tests for lib/network.sh

Describe 'network.sh'
    Include lib/common.sh
    Include lib/network.sh

    Describe 'generate_interfaces_config()'
        Context 'with static IP configuration'
            setup() {
                DETECTED_INTERFACE="eth0"
                DETECTED_IP_ADDRESS="192.168.1.100"
                DETECTED_NETMASK="255.255.255.0"
                DETECTED_GATEWAY="192.168.1.1"
                NETWORK_IS_DHCP=false
            }
            Before 'setup'

            It 'generates auto lo'
                When call generate_interfaces_config
                The output should include 'auto lo'
            End

            It 'generates iface lo inet loopback'
                When call generate_interfaces_config
                The output should include 'iface lo inet loopback'
            End

            It 'generates auto eth0'
                When call generate_interfaces_config
                The output should include 'auto eth0'
            End

            It 'generates inet static'
                When call generate_interfaces_config
                The output should include 'inet static'
            End

            It 'includes the IP address'
                When call generate_interfaces_config
                The output should include 'address 192.168.1.100'
            End

            It 'includes the netmask'
                When call generate_interfaces_config
                The output should include 'netmask 255.255.255.0'
            End

            It 'includes the gateway'
                When call generate_interfaces_config
                The output should include 'gateway 192.168.1.1'
            End
        End

        Context 'with DHCP configuration'
            setup() {
                DETECTED_INTERFACE="ens3"
                NETWORK_IS_DHCP=true
            }
            Before 'setup'

            It 'generates auto interface'
                When call generate_interfaces_config
                The output should include 'auto ens3'
            End

            It 'generates inet dhcp'
                When call generate_interfaces_config
                The output should include 'inet dhcp'
            End

            It 'does not include static address'
                When call generate_interfaces_config
                The output should not include 'address'
            End
        End
    End

    Describe 'generate_resolv_conf()'
        Context 'with single DNS server'
            setup() {
                DETECTED_DNS="8.8.8.8"
            }
            Before 'setup'

            It 'generates nameserver entry'
                When call generate_resolv_conf
                The output should equal 'nameserver 8.8.8.8'
            End
        End

        Context 'with multiple DNS servers'
            setup() {
                DETECTED_DNS="8.8.8.8 8.8.4.4 1.1.1.1"
            }
            Before 'setup'

            It 'generates multiple nameserver entries'
                When call generate_resolv_conf
                The line 1 should equal 'nameserver 8.8.8.8'
                The line 2 should equal 'nameserver 8.8.4.4'
                The line 3 should equal 'nameserver 1.1.1.1'
            End
        End
    End

    Describe 'generate_kernel_ip_param()'
        Context 'with DHCP'
            setup() {
                NETWORK_IS_DHCP=true
            }
            Before 'setup'

            It 'generates ip=dhcp'
                When call generate_kernel_ip_param
                The output should equal 'ip=dhcp'
            End
        End

        Context 'with static IP'
            setup() {
                NETWORK_IS_DHCP=false
                DETECTED_IP_ADDRESS="10.0.0.50"
                DETECTED_GATEWAY="10.0.0.1"
                DETECTED_NETMASK="255.255.255.0"
                DETECTED_HOSTNAME="myserver"
                DETECTED_INTERFACE="eth0"
            }
            Before 'setup'

            It 'generates kernel ip parameter'
                When call generate_kernel_ip_param
                The output should equal 'ip=10.0.0.50::10.0.0.1:255.255.255.0:myserver:eth0:off'
            End
        End
    End

    Describe 'print_network_summary()'
        setup() {
            DETECTED_INTERFACE="eth0"
            DETECTED_IP_ADDRESS="192.168.1.100"
            DETECTED_CIDR="24"
            DETECTED_NETMASK="255.255.255.0"
            DETECTED_GATEWAY="192.168.1.1"
            DETECTED_DNS="8.8.8.8"
            DETECTED_HOSTNAME="testhost"
            NETWORK_IS_DHCP=false
            DETECTED_ARCH="x86_64"
        }
        Before 'setup'

        It 'outputs interface'
            When call print_network_summary
            The output should include 'Interface:    eth0'
        End

        It 'outputs IP address with CIDR'
            When call print_network_summary
            The output should include 'IP Address:   192.168.1.100/24'
        End

        It 'outputs gateway'
            When call print_network_summary
            The output should include 'Gateway:      192.168.1.1'
        End

        It 'outputs hostname'
            When call print_network_summary
            The output should include 'Hostname:     testhost'
        End

        It 'outputs architecture'
            When call print_network_summary
            The output should include 'Architecture: x86_64'
        End
    End
End
