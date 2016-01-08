# Snabb NFV Test Suite Walk-through


## Prerequisites

On a machine with an *Intel 82599 10-Gigabit network interface card* and
*Docker* installed:

```
$ lspci | grep 82599
01:00.0 Ethernet controller: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection (rev 01)
01:00.1 Ethernet controller: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection (rev 01)

$ which docker
/usr/bin/docker
```

Clone the Snabb Switch repository and build Snabb Switch:

```
$ git clone https://github.com/snabbnfv-goodies/snabbswitch.git
[...]
$ cd snabbswitch
$ (cd src && scripts/dock.sh "(cd ..; make)")
[...]
```


## Test Suite for Linux virtual machines

```
$ (cd src && SNABB_PCI0=0000:01:00.0 \
             SNABB_PCI1=0000:01:00.1 \
             scripts/dock.sh program/snabbnfv/selftest.sh)
Defaulting to SNABB_TELNET0=5000
Defaulting to SNABB_TELNET1=5001
USING program/snabbnfv/test_fixtures/nfvconfig/test_functions/other_vlan.ports
Defaulting to MAC=52:54:00:00:00:
Defaulting to IP=fe80::5054:ff:fe00:
Defaulting to GUEST_MEM=512
Defaulting to HUGETLBFS=/hugetlbfs
Defaulting to QUEUES=1
Defaulting to QEMU=/root/.test_env/qemu/obj/x86_64-softmmu/qemu-system-x86_64
Waiting for VM listening on telnet port 5000 to get ready... [OK]
Waiting for VM listening on telnet port 5001 to get ready... [OK]
USING program/snabbnfv/test_fixtures/nfvconfig/test_functions/same_vlan.ports
1 packets transmitted, 1 received, 0% packet loss, time 0ms
PING succeded.
[  3]  0.0-10.0 sec  8.43 GBytes  7.24 Gbits/sec
IPERF succeded.
1 packets transmitted, 1 received, 0% packet loss, time 0ms
JUMBOPING succeded.
[  3]  0.0-10.0 sec  9.41 GBytes  8.09 Gbits/sec
IPERF succeded.
tx-checksumming: on
TX-CHECKSUMMING succeded.
tx-checksumming: on
TX-CHECKSUMMING succeded.
USING program/snabbnfv/test_fixtures/nfvconfig/test_functions/tx_rate_limit.ports
1 packets transmitted, 1 received, 0% packet loss, time 0ms
PING succeded.
IPERF (RATE_LIMITED) succeded.
IPERF rate is 814 Mbits/sec (900 Mbits/sec allowed).
RATE_LIMITED succeded.
1 packets transmitted, 1 received, 0% packet loss, time 0ms
JUMBOPING succeded.
IPERF (RATE_LIMITED) succeded.
IPERF rate is 814 Mbits/sec (900 Mbits/sec allowed).
RATE_LIMITED succeded.
USING program/snabbnfv/test_fixtures/nfvconfig/test_functions/rx_rate_limit.ports
1 packets transmitted, 1 received, 0% packet loss, time 0ms
PING succeded.
IPERF (RATE_LIMITED) succeded.
IPERF rate is 814 Mbits/sec (1200 Mbits/sec allowed).
RATE_LIMITED succeded.
1 packets transmitted, 1 received, 0% packet loss, time 0ms
JUMBOPING succeded.
IPERF (RATE_LIMITED) succeded.
IPERF rate is 814 Mbits/sec (1200 Mbits/sec allowed).
RATE_LIMITED succeded.
USING program/snabbnfv/test_fixtures/nfvconfig/test_functions/tunnel.ports
Dec 14 2015 14:12:51 nd_light: Resolved next-hop fe80::5054:ff:fe00:0 to 52:54:00:00:00:00
Dec 14 2015 14:12:51 nd_light: Resolved next-hop fe80::5054:ff:fe00:1 to 52:54:00:00:00:01
ND succeded.
1 packets transmitted, 1 received, 0% packet loss, time 0ms
PING succeded.
[  3]  0.0-10.0 sec  6.18 GBytes  5.31 Gbits/sec
IPERF succeded.
1 packets transmitted, 1 received, 0% packet loss, time 0ms
JUMBOPING succeded.
[  3]  0.0-10.0 sec  6.18 GBytes  5.31 Gbits/sec
IPERF succeded.
USING program/snabbnfv/test_fixtures/nfvconfig/test_functions/filter.ports
1 packets transmitted, 1 received, 0% packet loss, time 0ms
PING succeded.
Connection to fe80::5054:ff:fe00:0001%eth0 12345 port [tcp/*] succeeded!
PORTPROBE succeded.
Trying ::1...
Connected to localhost.
Escape character is '^]'.
nc -w 1 -q 1 -v  fe80::5054:ff:fe00:0001%eth0 12346
nc: connect to fe80::5054:ff:fe00:0001%eth0 port 12346 (tcp) timed out: Operation now in progress
root@fe00:~# 
root@fe00:~# Connection closed by foreign host.
FILTER succeded.
USING program/snabbnfv/test_fixtures/nfvconfig/test_functions/stateful-filter.ports
1 packets transmitted, 1 received, 0% packet loss, time 0ms
PING succeded.
Connection to fe80::5054:ff:fe00:0001%eth0 12345 port [tcp/*] succeeded!
PORTPROBE succeded.
Trying ::1...
Connected to localhost.
Escape character is '^]'.
nc -w 1 -q 1 -v  fe80::5054:ff:fe00:0001%eth0 12348
nc: connect to fe80::5054:ff:fe00:0001%eth0 port 12348 (tcp) timed out: Operation now in progress
root@fe00:~# 
root@fe00:~# Connection closed by foreign host.
FILTER succeded.
Trying ::1...
Connected to localhost.
Escape character is '^]'.
nc -w 1 -q 1 -v  fe80::5054:ff:fe00:0000%eth0 12340
nc: connect to fe80::5054:ff:fe00:0000%eth0 port 12340 (tcp) timed out: Operation now in progress
root@fe00:~# 
root@fe00:~# Connection closed by foreign host.
FILTER succeded.
```


## Test Suite for DPDK virtual machines

Run the Snabb NFV DPDK benchmark with varying packet sizes (64, 128, 256,
512, 1500 and 9000 bytes). First run is with DPDK 2.1, second run is with
DPDK 1.7 (with compatibility patches). Numbers are in Mpps (million
packets per second). **Notes:** The `l2fwd` application shipping with
DPDK 2.1 negotiates two additional Virtio-net options, “Indirect
Descriptors” and “Mergeable RX buffers”, and this triggers lower
performance in this benchmark environment. We are identifying the root
cause and then we expect to achieve consistent performance across DPDK
versions. The results below were obtained using an Intel(R) Xeon(R) CPU
E5-2650 0 @ 2.00GHz CPU.

```
$ (cd src && SNABB_TEST_IMAGE=snabbco/nfv-dpdk2.1 \
             SNABB_PCI_INTEL0=0000:01:00.0 \
             SNABB_PCI_INTEL1=0000:01:00.1 \
             scripts/dock.sh 'for c in 64 128 256 512 1500 9000; do echo $c $(CAPFILE=$c bench/snabbnfv-loadgen-dpdk); done')
64 2.788
128 2.455
256 2.183
512 2.318
1500 0.818
9000 0.138
```

```
$ (cd src && SNABB_TEST_IMAGE=snabbco/nfv-dpdk1.7 \
             SNABB_PCI_INTEL0=0000:01:00.0 \
             SNABB_PCI_INTEL1=0000:01:00.1 \
             scripts/dock.sh 'for c in 64 128 256 512 1500 9000; do echo $c $(CAPFILE=$c bench/snabbnfv-loadgen-dpdk); done')
64 4.358
128 4.477
256 3.923
512 2.312
1500 0.814
9000 # DPDK 1.7 did not support 900 byte packets
```
