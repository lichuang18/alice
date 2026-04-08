sleep 100
echo 1 > /sys/fs/cf2fs/nvme2n1/gc_urgent
sleep 200
echo 0 > /sys/fs/cf2fs/nvme2n1/gc_urgent

