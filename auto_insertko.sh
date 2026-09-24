make -j 16
umount ./test_mount
modprobe f2fs
rmmod cf2fs.ko
insmod cf2fs.ko
sudo mkfs.f2fs -f -O extra_attr,compression /dev/nvme1n1
mount -t cf2fs  -o mode=lfs,compress_algorithm=lz4,compress_log_size=2,compress_mode=fs,compress_extension='*' /dev/nvme1n1 ./test_mount 
# mount -t ef2fs  -o mode=lfs /dev/nvme2n1 /mnt
