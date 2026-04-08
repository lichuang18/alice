make -j 16
umount ./test_mount
modprobe f2fs
rmmod cf2fs.ko
insmod cf2fs.ko
mkfs.f2fs -f /dev/nvme1n1
mount -t cf2fs  -o mode=lfs /dev/nvme1n1 ./test_mount 
# mount -t ef2fs  -o mode=lfs /dev/nvme2n1 /mnt
