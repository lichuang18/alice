make -j 16
umount /mnt
modprobe f2fs
rmmod cf2fs.ko
insmod cf2fs.ko
mkfs.f2fs -f /dev/nvme0n1
mount -t cf2fs  -o mode=lfs /dev/nvme0n1 /mnt 
# mount -t ef2fs  -o mode=lfs /dev/nvme2n1 /mnt
