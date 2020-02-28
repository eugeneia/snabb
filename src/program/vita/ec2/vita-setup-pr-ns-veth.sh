#!/usr/bin/env bash

# Set up veth pair with one end in a private network namespace for Vita
# testing.

vita_priv_mac=$1 # 02:00:00:00:00:02
vita_priv_ip=$2 # 10.10.1.1
vita_priv_nh_ip=$3 # 10.10.1.2
vita_priv_route=$4 # 10.10.2.0/24
vita_pub_if=$5 # eth1
vita_pub_mac=$6
vita_pub_ip=$7
vita_pub_nh_ip=$8
vita_pub_gw_ip=$9

pr0=pr
vpr0=v$pr0

ip netns add $pr0
ip netns exec $pr0 ip link set lo up

ip link add $vpr0 type veth peer name $pr0
ip link set $pr0 netns $pr0

ip link set $vpr0 address $vita_priv_mac
ip address add dev $vpr0 local $vita_priv_ip
ip link set $vpr0 up

ip netns exec $pr0 ethtool --offload $pr0  rx off tx off
ip netns exec $pr0 ip address add dev $pr0 local $vita_priv_nh_ip/24
ip netns exec $pr0 ip link set $pr0 mtu 1440
ip netns exec $pr0 ip link set $pr0 up
ip netns exec $pr0 ip route add $vita_priv_route via $vita_priv_ip src $vita_priv_nh_ip dev $pr0
ip netns exec $pr0 ip route add default via $vita_priv_nh_ip dev $pr0

cat <<EOF
public-interface4 {
  ifname $vita_pub_if;
  ip $vita_pub_ip;
  mac $vita_pub_mac;
  nexthop-ip $vita_pub_nh_ip;
}
private-interface4 {
  ifname $vpr0;
  ip $vita_priv_ip;
  mac $vita_priv_mac;
  nexthop-ip $vita_priv_nh_ip;
}
route4 {
  id test1;
  gateway { ip $vita_pub_gw_ip; }
  net "$vita_priv_route";
  preshared-key 0000000000000000000000000000000000000000000000000000000000000001;
  spi 1001;
}
EOF
