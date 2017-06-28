#!/usr/bin/env bash

SKIPPED_CODE=43

if [ -z "$SNABB_PCI0" ]; then
    export SNABB_PCI0=soft
fi
if [ -z "$SNABB_PCI1" ]; then
    export SNABB_PCI1=soft
fi
if [ -z "$SNABB_TELNET0" ]; then
    export SNABB_TELNET0=5000
    echo "Defaulting to SNABB_TELNET0=$SNABB_TELNET0"
fi
if [ -z "$SNABB_TELNET1" ]; then
    export SNABB_TELNET1=5001
    echo "Defaulting to SNABB_TELNET1=$SNABB_TELNET1"
fi
if [ -z "$SNABB_IPERF_BENCH_CONF0" ]; then
    export SNABB_IPERF_BENCH_CONF0=program/snabbnfv/test_fixtures/nfvconfig/test_functions2/bare0.port
    echo "Defaulting to SNABB_IPERF_BENCH_CONF0=$SNABB_IPERF_BENCH_CONF0"
fi
if [ -z "$SNABB_IPERF_BENCH_CONF1" ]; then
    export SNABB_IPERF_BENCH_CONF1=program/snabbnfv/test_fixtures/nfvconfig/test_functions2/bare1.port
    echo "Defaulting to SNABB_IPERF_BENCH_CONF1=$SNABB_IPERF_BENCH_CONF1"
fi

TESTCONFPATH0="/tmp/snabb_nfv_selftest_ports-0.$$"
TESTCONFPATH1="/tmp/snabb_nfv_selftest_ports-1.$$"

# Usage: run_telnet <port> <command> [<sleep>]
# Runs <command> on VM listening on telnet <port>. Waits <sleep> seconds
# for before closing connection. The default of <sleep> is 2.
function run_telnet {
    (echo "$2"; sleep ${3:-2}) \
        | telnet localhost $1 2>&1
}

# Usage: agrep <pattern>
# Like grep from standard input except that if <pattern> doesn't match
# the whole output is printed and status code 1 is returned.
function agrep {
    input=$(cat);
    if ! echo "$input" | grep "$1"
    then
        echo "$input"
        return 1
    fi
}

# Usage: load_configs <config0> <config1>
# Copies <path> to TESTCONFPATH and sleeps for a bit.
function load_configs {
    echo "USING"
    echo "  $1"
    echo "  $2"
    cp "$1" "$TESTCONFPATH0"
    cp "$2" "$TESTCONFPATH1"
    sleep 2
}

function start_test_env {
    if ! source program/snabbnfv/test_env/test_env.sh; then
        echo "Could not load test_env."; exit 1
    fi

    if ! snabb $SNABB_PCI0 "snabbnfv traffic $SNABB_PCI0 $TESTCONFPATH0 vhost_%s.sock"; then
        echo "Could not start snabb."; exit 1
    fi

    if ! snabb $SNABB_PCI1 "snabbnfv traffic $SNABB_PCI1 $TESTCONFPATH1 vhost_%s.sock"; then
        echo "Could not start snabb."; exit 1
    fi

    if ! qemu $SNABB_PCI0 vhost_A.sock $SNABB_TELNET0; then
        echo "Could not start qemu 0."; exit 1
    fi

    if ! qemu $SNABB_PCI1 vhost_B.sock $SNABB_TELNET1; then
        echo "Could not start qemu 1."; exit 1
    fi

    # Wait until VMs are ready.
    wait_vm_up $SNABB_TELNET0
    wait_vm_up $SNABB_TELNET1

    # Manually set ip addresses.
    run_telnet $SNABB_TELNET0 "ifconfig eth0 up" >/dev/null
    run_telnet $SNABB_TELNET1 "ifconfig eth0 up" >/dev/null
    run_telnet $SNABB_TELNET0 "ip -6 addr add $(ip 0) dev eth0" >/dev/null
    run_telnet $SNABB_TELNET1 "ip -6 addr add $(ip 1) dev eth0" >/dev/null
}

function cleanup {
    # Clean up temporary config location.
    rm -f "$TESTCONFPATH0" "$TESTCONFPATH1"
    exit
}

# Set up graceful `exit'.
trap cleanup EXIT HUP INT QUIT TERM

# Usage: wait_vm_up <port>
# Blocks until ping to 0::0 suceeds.
function wait_vm_up {
    local timeout_counter=0
    local timeout_max=50
    echo -n "Waiting for VM listening on telnet port $1 to get ready..."
    while ( ! (run_telnet $1 "ping6 -c 1 0::0" | grep "1 received" \
        >/dev/null) ); do
        # Time out eventually.
        if [ $timeout_counter -gt $timeout_max ]; then
            echo " [TIMEOUT]"
            exit 1
        fi
        timeout_counter=$(expr $timeout_counter + 1)
        sleep 2
    done
    echo " [OK]"
}

function assert {
    if [ $2 == "0" ]; then echo "$1 succeded."
    else
        echo "$1 failed."
        echo
        echo "qemu0.log:"
        cat "qemu0.log"
        echo
        echo
        echo "qemu1.log:"
        cat "qemu1.log"
        echo
        echo
        echo "snabb0.log:"
        cat "snabb0.log"
        echo
        echo
        echo "snabb1.log:"
        cat "snabb1.log"
        exit 1
    fi
}

# Usage: test_jumboping <telnet_port0> <telnet_port1> <dest_ip>
# Set large "jumbo" MTU to VMs listening on <telnet_port0> and
# <telnet_port1>. Assert successful jumbo ping from VM listening on
# <telnet_port0> to <dest_ip>.
function test_jumboping {
    run_telnet $1 "ip link set dev eth0 mtu 9100" >/dev/null
    run_telnet $2 "ip link set dev eth0 mtu 9100" >/dev/null
    run_telnet $1 "ping6 -s 9000 -c 1 $3" \
        | agrep "1 packets transmitted, 1 received"
    assert JUMBOPING $?
}

# Usage: test_iperf <telnet_port0> <telnet_port1> <dest_ip>
# Assert successful (whatever that means) iperf run with <telnet_port1>
# listening and <telnet_port0> sending to <dest_ip>.
function test_iperf {
    run_telnet $2 "nohup iperf -d -s -V &" >/dev/null
    sleep 2
    run_telnet $1 "iperf -c $3 -f g -V" 20 \
        | agrep "s/sec"
    assert IPERF $?
}

# Usage: iperf_bench [<mode>] [<config>]
# Run iperf benchmark. If <mode> is "jumbo", jumboframes will be enabled.
# <config> defaults to same_vlan.ports.
function iperf_bench {
    load_configs "$SNABB_IPERF_BENCH_CONF0" "$SNABB_IPERF_BENCH_CONF1"

    if [ "$1" = "jumbo" ]; then
        test_jumboping $SNABB_TELNET0 $SNABB_TELNET1 "$(ip 1)%eth0" \
            2>&1 >/dev/null
    fi
    Gbits=$(test_iperf $SNABB_TELNET0 $SNABB_TELNET1 "$(ip 1)%eth0" \
        | egrep -o '[0-9\.]+ Gbits/sec' | cut -d " " -f 1)
    if [ "$1" = "jumbo" ]; then
        echo IPERF-JUMBO "$Gbits"
    else
        echo IPERF-1500 "$Gbits"
    fi
}

load_configs \
    program/snabbnfv/test_fixtures/nfvconfig/test_functions2/other_vlan0.port \
    program/snabbnfv/test_fixtures/nfvconfig/test_functions2/other_vlan1.port
start_test_env
iperf_bench "$2" "$3"
exit 0
