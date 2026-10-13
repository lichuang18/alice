make -j 16
umount ./test_mount
modprobe f2fs
rmmod cf2fs.ko
insmod cf2fs.ko
sudo mkfs.f2fs -f -O extra_attr,compression /dev/nvme1n1
# mount -t cf2fs  -o mode=lfs,compress_algorithm=lz4,compress_log_size=2,compress_mode=fs,compress_extension='*' /dev/nvme1n1 ./test_mount 
mount -t cf2fs  -o mode=lfs,background_gc=off,nodiscard,compress_algorithm=lz4,compress_log_size=2,compress_mode=fs,compress_extension='*' /dev/nvme1n1 ./test_mount 

# 排除gc discard的干扰
# background_gc=off,nodiscard

echo "before blocks:"
sync
sync

echo "self interface count:"
cat /sys/fs/cf2fs/nvme1n1/physical_data_blocks


echo "f2fs proc interface count:"
# print result, used  xxx. blocks
awk '
NR > 2 {
    for (i = 2; i <= NF; i++) {
        if ($i ~ /^[0-2]\|[0-9]+$/) {
            split($i, a, "|");
            sum += a[2];
        }
    }
}
END {
    printf "%.0f\n", sum;
}' /proc/fs/f2fs/nvme1n1/segment_info

echo "before blocks:"


echo "start write: co-pack"
# 数据集enwik9
cp /home/lch/work/compress/data/enwik9_raw/enwik9 /home/lch/work/compress/alice/test_mount  
# 数据集fdroid
# cp -r /home/lch/work/compress/data/fdriod/fdroid_raw/* /home/lch/work/compress/alice/test_mount  

sync
echo "after blocks:"
sync
sync

echo "self interface count2:"
cat /sys/fs/cf2fs/nvme1n1/physical_data_blocks


echo "f2fs proc interface count2:"
# print result, used  xxx. blocks
awk '
NR > 2 {
    for (i = 2; i <= NF; i++) {
        if ($i ~ /^[0-2]\|[0-9]+$/) {
            split($i, a, "|");
            sum += a[2];
        }
    }
}
END {
    printf "%.0f\n", sum;
}' /proc/fs/f2fs/nvme1n1/segment_info