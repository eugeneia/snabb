#!/usr/bin/env bash

numactl -C  2 -m 0 ./snabb snsh saturate.lua 01:00.0 &
numactl -C  3 -m 0 ./snabb snsh saturate.lua 01:00.1 &
numactl -C  4 -m 0 ./snabb snsh saturate.lua 03:00.0 &
numactl -C  5 -m 0 ./snabb snsh saturate.lua 03:00.1 &
numactl -C  6 -m 0 ./snabb snsh saturate.lua 05:00.0 &
numactl -C  7 -m 0 ./snabb snsh saturate.lua 05:00.1 &
numactl -C  8 -m 0 ./snabb snsh saturate.lua 07:00.0 &
numactl -C  9 -m 0 ./snabb snsh saturate.lua 07:00.1 &
numactl -C 10 -m 0 ./snabb snsh saturate.lua 09:00.0 &
numactl -C 11 -m 0 ./snabb snsh saturate.lua 09:00.1 &
numactl -C 13 -m 1 ./snabb snsh saturate.lua 82:00.0 &
numactl -C 14 -m 1 ./snabb snsh saturate.lua 82:00.1 &
numactl -C 15 -m 1 ./snabb snsh saturate.lua 84:00.0 &
numactl -C 16 -m 1 ./snabb snsh saturate.lua 84:00.1 &
numactl -C 17 -m 1 ./snabb snsh saturate.lua 86:00.0 &
numactl -C 18 -m 1 ./snabb snsh saturate.lua 86:00.1 &
numactl -C 19 -m 1 ./snabb snsh saturate.lua 88:00.0 &
numactl -C 20 -m 1 ./snabb snsh saturate.lua 88:00.1 &
numactl -C 21 -m 1 ./snabb snsh saturate.lua 8a:00.0 &
numactl -C 22 -m 1 ./snabb snsh saturate.lua 8a:00.1 &
sleep 25
