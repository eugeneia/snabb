#!/bin/bash

ip tuntap add snabbtest mode tap
ip link set up dev snabbtest
ip link set address 02:01:02:03:04:08 dev snabbtest

ip link add snabbmonitor type dummy
ip link set snabbmonitor up

./snabb snabbnfv traffic -k 10 -l 10 $1 \
    program/snabbnfv/test_fixtures/nfvconfig/test_functions/veth_mirror.port \
    "veth_%s" &
snabb=$!

tcpdump -c 4 -i snabbtest -w snabbtest.pcap &
tcpdump -c 4 -i snabbmonitor -w snabbmonitor.pcap &

sleep 2

ping -c 10 f080::1%snabbtest

kill $snabb
ip link delete snabbtest
ip link delete snabbmonitor
