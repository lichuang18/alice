
#!/usr/bin/env bash
set -euo pipefail

cd /home/lch/work/compress/alice

DEV=/dev/nvme1n1
MNT=/home/lch/work/compress/alice/test_mount
ALGO=lzo
# lzo lz4 zstd

# 切换数据集：enwik9、fdroid、silesia、linux_kernel
DATASET=silesia

RESULT_DIR=/home/lch/work/compress/fig1_results
mkdir -p "$RESULT_DIR"

NAME=$(basename "$DEV")
STAT="/sys/fs/cf2fs/$NAME/physical_data_blocks"
OUT="$RESULT_DIR/copack_${DATASET}_${ALGO}_$(date +%Y%m%d_%H%M%S)"

# 1. 编译、卸载旧模块
make -j16

if mountpoint -q "$MNT"; then
    umount "$MNT"
fi

# 卸载旧的 CoPack
if lsmod | grep '^cf2fs '; then
    echo "[INFO] Removing old cf2fs module..."
    rmmod cf2fs
fi

# 重新加载原生 f2fs，为 cf2fs 提供依赖
if lsmod | grep '^f2fs '; then
    echo "[INFO] Removing old f2fs module..."
    modprobe -r f2fs
fi

echo "[INFO] Loading native f2fs..."
modprobe f2fs

echo "[INFO] Loading cf2fs..."
insmod ./cf2fs.ko

echo "[INFO] CoPack initialized successfully."

# 2. 格式化：会清空设备所有数据
echo "WARNING: ALL DATA ON $DEV WILL BE ERASED"
read -r -p "Continue? [y/Y]: " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || exit 1

mkfs.f2fs -f -O extra_attr,compression "$DEV"

# 3. 挂载 CoPack
mkdir -p "$MNT"

mount -t cf2fs \
  -o "mode=lfs,background_gc=off,nodiscard,compress_algorithm=$ALGO,compress_log_size=2,compress_mode=fs,compress_extension=*" \
  "$DEV" "$MNT"

findmnt -T "$MNT" -o SOURCE,FSTYPE,OPTIONS > "${OUT}_mount.txt"
cat "${OUT}_mount.txt"

# 检查 CoPack 物理块统计接口
if [[ ! -r "$STAT" ]]; then
    echo "[ERROR] CoPack sysfs interface not found: $STAT"
    exit 1
fi

echo "[INFO] CoPack physical block interface ready."

# 4. 创建目标目录
mkdir -p "$MNT/data"

# 5. 写入前统计
sync

BEFORE=$(cat "$STAT")

echo "Before: sysfs=$BEFORE"

# 6. 写入数据集
case "$DATASET" in
  enwik9)
    cp --reflink=never --sparse=never \
      /home/lch/work/compress/data/enwik9_raw/enwik9 \
      "$MNT/data/enwik9"
    ;;
  fdroid)
    cp -R --reflink=never --sparse=never \
      /home/lch/work/compress/data/fdriod/fdroid_raw/. \
      "$MNT/data/"
    ;;
  silesia)
    cp -R --reflink=never --sparse=never \
      /home/lch/work/compress/data/silesia/silesia_raw/. \
      "$MNT/data/"
    ;;
  linux_kernel)
    cp -R --reflink=never --sparse=never \
      /home/lch/work/compress/data/linux_kernel/linux_kernel_raw/. \
      "$MNT/data/"
    ;;
  *)
    echo "Unknown dataset: $DATASET"
    exit 1
    ;;
esac

# 7. 确保压缩写回完成
sync

# 8. 写入后统计
AFTER=$(cat "$STAT")

echo "After: sysfs=$AFTER"

# 9. 计算空间占用
USED=$((AFTER - BEFORE))
BYTES=$((USED * 4096))

echo "============================"
echo "Dataset:        $DATASET"
echo "Algorithm:      $ALGO"
echo "Before blocks:  $BEFORE"
echo "After blocks:   $AFTER"
echo "Physical blocks:$USED"
echo "Physical bytes: $BYTES"
echo "============================"

# 10. 抽查压缩属性
echo "Compression attribute check:"
find "$MNT/data" -type f -print -quit |
    xargs -r lsattr

# 11. 保存实验数据
echo "dataset,algorithm,system,before,after,used_blocks,physical_bytes" \
  > "${OUT}.csv"

echo "$DATASET,$ALGO,CoPack,$BEFORE,$AFTER,$USED,$BYTES" \
  >> "${OUT}.csv"

echo "Saved: ${OUT}.csv"

# 保留挂载状态，方便检查文件和 dmesg
# 检查结束后手动 umount "$MNT"
