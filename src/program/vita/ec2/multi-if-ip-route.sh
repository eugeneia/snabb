#!/usr/bin/env bash

# Configure a secondary ip on a secondary interface on Linux
# See https://unix.stackexchange.com/a/507208/392820

interface=$1
ip=$2
default_gw=$3
route_table=$4 # an integer, e.g. 1000

ip route add default via $default_gw dev $interface table $route_table
ip route add $ip dev $interface table $route_table
ip rule add from $ip lookup $route_table
