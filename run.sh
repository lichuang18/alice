rm -rf /tmp/copack_parts
mkdir -p /tmp/copack_parts


# 先制造小一点的 dirty workload，例如 64 个 1-MiB 文件：
split -b 1M -d -a 4 \
    ../data/enwik9_raw/enwik9\
    /tmp/copack_parts/p

for f in $(ls /tmp/copack_parts/p* | head -64); do
    cp "$f" ./test_mount/
done

sync

# 删除一半
i=0
for f in ./test_mount/p*; do
    if [ $((i % 2)) -eq 0 ]; then
        rm -f "$f"
    fi
    i=$((i + 1))
done

sync

# 开启后台GC
sync
umount ./test_mount

mount -t cf2fs \
  -o background_gc=on,mode=lfs,compress_algorithm=lz4,compress_log_size=2,compress_mode=fs,compress_extension='*' \
  /dev/nvme1n1 ./test_mount

dmesg -C

echo 1 > /sys/fs/cf2fs/nvme1n1/gc_urgent
sleep 5
echo 0 > /sys/fs/cf2fs/nvme1n1/gc_urgent