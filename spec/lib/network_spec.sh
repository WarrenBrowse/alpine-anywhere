#!/bin/sh
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

    Describe 'generate_interfaces_config() IPv6'
        Context 'static v4 + v6'
            setup() {
                DETECTED_INTERFACE="eth0"
                DETECTED_IP_ADDRESS="50.7.46.90"
                DETECTED_NETMASK="255.255.255.248"
                DETECTED_GATEWAY="50.7.46.89"
                NETWORK_IS_DHCP=false
                DETECTED_IPV6_ADDRESS="2001:49f0:d086:1003::2"
                DETECTED_IPV6_CIDR="64"
                DETECTED_IPV6_GATEWAY="2001:49f0:d086:1003::1"
            }
            Before 'setup'

            It 'emits an inet6 static stanza'
                When call generate_interfaces_config
                The output should include 'inet6 static'
            End
            It 'includes the v6 address'
                When call generate_interfaces_config
                The output should include 'address 2001:49f0:d086:1003::2'
            End
            It 'includes the v6 netmask (prefix)'
                When call generate_interfaces_config
                The output should include 'netmask 64'
            End
            It 'includes the v6 gateway'
                When call generate_interfaces_config
                The output should include 'gateway 2001:49f0:d086:1003::1'
            End
            It 'still emits the v4 static stanza'
                When call generate_interfaces_config
                The output should include 'address 50.7.46.90'
            End
            It 'honors a runtime interface override argument'
                When call generate_interfaces_config wlan0
                The output should include 'auto wlan0'
            End
        End

        Context 'v4-only host (no v6)'
            setup() {
                DETECTED_INTERFACE="eth0"
                DETECTED_IP_ADDRESS="203.0.113.5"
                DETECTED_NETMASK="255.255.255.0"
                DETECTED_GATEWAY="203.0.113.1"
                NETWORK_IS_DHCP=false
                DETECTED_IPV6_ADDRESS=""
            }
            Before 'setup'

            It 'emits no inet6 stanza when v6 is absent'
                When call generate_interfaces_config
                The output should not include 'inet6'
            End
        End
    End

    Describe 'apply_network_overrides()'
        Include lib/validate.sh
        setup() {
            DETECTED_INTERFACE="eth0"
            DETECTED_IP_ADDRESS="203.0.113.5"
            DETECTED_CIDR="24"
            DETECTED_NETMASK="255.255.255.0"
            DETECTED_GATEWAY="203.0.113.1"
            NETWORK_IS_DHCP=false
            DETECTED_DNS="8.8.8.8"
            DETECTED_HOSTNAME="host"
            DETECTED_IPV6_ADDRESS=""
            DETECTED_IPV6_CIDR=""
            DETECTED_IPV6_GATEWAY=""
            IPV4_OVERRIDE=""; IPV4_GATEWAY_OVERRIDE=""
            IPV6_OVERRIDE=""; IPV6_GATEWAY_OVERRIDE=""; DNS_OVERRIDE=""
        }
        Before 'setup'

        It 'adds IPv6 to a v4-only host (FDC case)'
            IPV6_OVERRIDE="2001:db8::2/64"
            IPV6_GATEWAY_OVERRIDE="2001:db8::1"
            When call apply_network_overrides
            The variable DETECTED_IPV6_ADDRESS should equal '2001:db8::2'
            The variable DETECTED_IPV6_CIDR should equal '64'
            The variable DETECTED_IPV6_GATEWAY should equal '2001:db8::1'
            The stderr should be present
        End

        It 'defaults the v6 prefix to 64 when omitted'
            IPV6_OVERRIDE="2001:db8::2"
            When call apply_network_overrides
            The variable DETECTED_IPV6_CIDR should equal '64'
            The stderr should be present
        End

        It 'overrides IPv4 address and recomputes the netmask'
            IPV4_OVERRIDE="10.0.0.5/16"
            When call apply_network_overrides
            The variable DETECTED_IP_ADDRESS should equal '10.0.0.5'
            The variable DETECTED_CIDR should equal '16'
            The variable DETECTED_NETMASK should equal '255.255.0.0'
            The stderr should be present
        End

        It 'normalizes comma-separated DNS overrides'
            DNS_OVERRIDE="1.1.1.1,9.9.9.9"
            When call apply_network_overrides
            The variable DETECTED_DNS should equal '1.1.1.1 9.9.9.9'
            The stderr should be present
        End

        It 'preserves DHCP when adding IPv6 only (does not switch v4 to static)'
            NETWORK_IS_DHCP=true
            IPV6_OVERRIDE="2001:db8::2/64"
            When call apply_network_overrides
            The variable NETWORK_IS_DHCP should equal 'true'
            The variable DETECTED_IPV6_ADDRESS should equal '2001:db8::2'
            The stderr should be present
        End

        It 'switches to static only when IPv4 is explicitly overridden'
            NETWORK_IS_DHCP=true
            IPV4_OVERRIDE="10.0.0.5/24"
            When call apply_network_overrides
            The variable NETWORK_IS_DHCP should equal 'false'
            The stderr should be present
        End
    End

    Describe 'generate_interfaces_config() DHCP v4 + static v6'
        setup() {
            DETECTED_INTERFACE="eth0"
            NETWORK_IS_DHCP=true
            DETECTED_IPV6_ADDRESS="2001:db8::2"
            DETECTED_IPV6_CIDR="64"
            DETECTED_IPV6_GATEWAY="2001:db8::1"
        }
        Before 'setup'

        It 'keeps v4 on dhcp'
            When call generate_interfaces_config
            The output should include 'inet dhcp'
        End
        It 'still adds the static v6 stanza'
            When call generate_interfaces_config
            The output should include 'inet6 static'
            The output should include 'address 2001:db8::2'
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

    Describe 'detect_hostname()'
        log_step() { :; }
        log_info() { :; }
        # Stand in for the SSH probe of the source system's hostname.
        ssh_exec_capture() { echo "old-provider-default"; }

        It 'prefers HOSTNAME_OVERRIDE over the source system hostname'
            HOSTNAME_OVERRIDE="exit-sg-sin1"
            When call detect_hostname
            The variable DETECTED_HOSTNAME should equal "exit-sg-sin1"
        End

        It 'falls back to the detected hostname when no override is given'
            HOSTNAME_OVERRIDE=""
            When call detect_hostname
            The variable DETECTED_HOSTNAME should equal "old-provider-default"
        End
    End
End
