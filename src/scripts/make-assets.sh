#!/bin/bash

set -e

TMP=/tmp/snabb-test_env-assets-build
OUT=$1

mkdir $TMP/

git clone --depth 1 https://github.com/SnabbCo/qemu $OUT/qemu
mkdir $OUT/qemu/obj
(cd $OUT/qemu/obj; ../configure --target-list=x86_64-softmmu && make -j$(nproc))

git clone --depth 1 git://kernel.ubuntu.com/ubuntu/ubuntu-trusty.git $TMP/ubuntu-trusty
(cd $TMP/ubuntu-trusty
    cat debian.master/config/config.common.ubuntu \
        debian.master/config/amd64/config.common.amd64 \
        debian.master/config/amd64/config.flavour.generic > .config
    echo CONFIG_VIRTIO_NET=m >> .config
    echo CONFIG_UIO=m >> .config
    echo CONFIG_DEBUG_INFO=n >> .config
    make deb-pkg -j$(nproc)
    make M=drivers/net virtio_net.ko -j$(nproc)
    make M=drivers/uio uio.ko -j$(nproc))
cp $TMP/ubuntu-trusty/arch/x86/boot/bzImage $OUT/

dd if=/dev/zero of=$OUT/qemu.img bs=1MiB count=2048
mkfs.ext4 -F $OUT/qemu.img
mkdir $TMP/mnt
mount -o loop $OUT/qemu.img $TMP/mnt
debootstrap --arch=amd64 trusty $TMP/mnt
cp $TMP/mnt/etc/init/tty1.conf $TMP/mnt/etc/init/ttyS0.conf
sed -i '$s/.*/exec \/sbin\/getty -8 115200 ttyS0 linux -a root/' $TMP/mnt/etc/init/ttyS0.conf
printf "auto eth0\niface eth0 inet manual\ndns-nameserver 8.8.8.8\n" > $TMP/mnt/etc/network/interfaces
echo vm > $TMP/mnt/etc/hostname
echo "deb http://archive.ubuntu.com/ubuntu trusty universe" >> $TMP/mnt/etc/apt/sources.list
chroot $TMP/mnt apt-get update
chroot $TMP/mnt apt-get install -y ethtool tcpdump netcat iperf
# Install virtio_net and uio modules
mkdir -p $TMP/mnt/lib/modules/3.13.11-ckt25
cp $TMP/ubuntu-trusty/drivers/net/virtio_net.ko $TMP/mnt/lib/modules/3.13.11-ckt25/
cp $TMP/ubuntu-trusty/drivers/uio/uio.ko $TMP/mnt/lib/modules/3.13.11-ckt25/
chroot $TMP/mnt depmod 3.13.11-ckt25
umount $TMP/mnt
# Build DPDK version.
cp $OUT/qemu.img $OUT/qemu-dpdk.img
mount -o loop $OUT/qemu-dpdk.img $TMP/mnt
mkdir $TMP/mnt/hugetlbfs
cp $TMP/linux-headers-3.13.11-ckt25_3.13.11-ckt25-1_amd64.deb $TMP/mnt/root
chroot $TMP/mnt dpkg -i /root/linux-headers-3.13.11-ckt25_3.13.11-ckt25-1_amd64.deb
chroot $TMP/mnt apt-get install -y build-essential screen python pciutils
git clone https://github.com/virtualopensystems/dpdk.git $TMP/mnt/root/dpdk
chroot $TMP/mnt bash -c "(cd /root/dpdk; RTE_KERNELDIR=/lib/modules/3.13.11-ckt25/build/ make T=x86_64-native-linuxapp-gcc config -j$(nproc))"
chroot $TMP/mnt bash -c "(cd /root/dpdk; RTE_KERNELDIR=/lib/modules/3.13.11-ckt25/build/ make T=x86_64-native-linuxapp-gcc install -j$(nproc))"
chroot $TMP/mnt bash -c "(cd /root/dpdk; RTE_KERNELDIR=/lib/modules/3.13.11-ckt25/build/ make T=x86_64-native-linuxapp-gcc examples -j$(nproc) || true)"
cat > $TMP/mnt/etc/rc.local <<EOF
#!/bin/sh
mount -t hugetlbfs nodev /hugetlbfs
echo 64 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
modprobe uio
insmod /root/dpdk/x86_64-native-linuxapp-gcc/kmod/igb_uio.ko
/root/dpdk/tools/dpdk_nic_bind.py --bind=igb_uio 00:03.0
screen -d -m /root/dpdk/examples/l2fwd/x86_64-native-linuxapp-gcc/l2fwd -c 0x1 -n1 -- -p 0x1
exit 0
EOF
echo "blacklist virtio_net" >> $TMP/mnt/etc/modprobe.d/blacklist
umount $TMP/mnt

rm -rf $TMP/
