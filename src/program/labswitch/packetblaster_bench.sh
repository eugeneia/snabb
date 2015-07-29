#!/bin/bash

if [ -z "$TESTPCI0A" ];     then echo "Need TESTPCI0A";    exit 1; fi
if [ -z "$TESTPCI0B" ];     then echo "Need TESTPCI0B";    exit 1; fi
if [ -z "$TESTPCI1A" ];     then echo "Need TESTPCI1A";    exit 1; fi
if [ -z "$TESTPCI1B" ];     then echo "Need TESTPCI1B";    exit 1; fi

if [ -z "$PACKETS" ]; then
    echo "Defaulting to PACKETS=100e6"
    export PACKETS=100e6
fi

if [ -z "$CAPFILE" ]; then
    echo "Defaulting to CAPFILE=64"
    export CAPFILE=64
fi

if [ -z "$DURATION" ]; then
    echo "Defaulting to DURATION=5"
    export DURATION=5
fi

cat > /tmp/labswitch_bench.conf <<EOF
return {
  port1 = { apps = { nic1 = { "apps.intel.intel_app/Intel82599",
                              { pciaddr = "$TESTPCI0B" } } },
            rx = "nic1.rx",
            tx = "nic1.tx" },
  port2 = { apps = { nic2 = { "apps.intel.intel_app/Intel82599",
                              { pciaddr = "$TESTPCI1B" } } },
            rx = "nic2.rx",
            tx = "nic2.tx" }
}
EOF

source program/snabbnfv/test_env/test_env.sh

packetblaster $TESTPCI0A $CAPFILE
packetblaster $TESTPCI1A $CAPFILE
numactl \
    --cpunodebind=$(pci_node $TESTPCI0A) \
    --membind=$(pci_node $TESTPCI0A) \
    ./snabb labswitch -B $DURATION /tmp/labswitch_bench.conf

rm /tmp/labswitch_bench.conf
