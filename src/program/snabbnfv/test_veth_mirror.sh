#!/bin/bash

ip tuntap add snabbtest0 mode tap
ip link set up dev snabbtest0
ip tuntap add snabbtest1 mode tap
ip link set up dev snabbtest1

./snabb snabbnfv traffic -k 10 -l 10 $1 \
    program/snabbnfv/test_fixtures/nfvconfig/test_functions/veth_mirror.ports \
    "snabbtest%s" &
snabb=$!

tcpdump -i snabbtest0 -w snabbtest0.pcap &
tcpdump -i snabbtest1 -w snabbtest1.pcap &

sleep 6

ping6 -c 10 fe80::1%snabbtest0

kill $snabb
ip link delete snabbtest0
ip link delete snabbmonitor0
ip link delete snabbtest1
ip link delete snabbmonitor1
