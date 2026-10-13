
#!/usr/bin/env bash
set -euo pipefail

cd /home/lch/work/compress/alice

DEV=/dev/nvme1n1
MNT=/home/lch/work/compress/alice/test_mount
ALGO=lzo
# lzo lz4 zstd

# 切换数据集：enwik9、fdroid、silesia、linux_kernel
DATASET=linux_kernel

RESULT_DIR=/home/lch/work/compress/fig1_results
mkdir -p "$RESULT_DIR"

NAME=$(basename "$DEV")
PROC="/proc/fs/f2fs/$NAME/segment_info"
OUT="$RESULT_DIR/f2fscomp_${DATASET}_${ALGO}_$(date +%Y%m%d_%H%M%S)"

# proc SIT 统计：Data Segment (0/1/2) 的有效物理块数
proc_blocks() {
    awk '
    NR > 2 {
        for (i = 2; i <= NF; i++) {
            if ($i ~ /^[0-2]\|[0-9]+$/) {
                split($i, a, "|");
                sum += a[2];
                count++;
            }
        }
    }
    END {
        if (count == 0) exit 1;
        printf "%.0f\n", sum;
    }' "$PROC"
}

# 1. 卸载旧文件系统
if mountpoint -q "$MNT"; then
    umount "$MNT"
fi

# 防止测试设备仍挂载在其他目录
if findmnt -rn -S "$DEV" | grep .; then
    echo "ERROR: $DEV is still mounted"
    exit 1
fi

# 2. 卸载旧的 cf2fs
if lsmod | grep '^cf2fs '; then
    echo "[INFO] Removing old cf2fs module..."
    rmmod cf2fs
fi

# 3. 重新加载原生 f2fs，恢复 procfs 注册
if lsmod | grep '^f2fs '; then
    echo "[INFO] Removing old f2fs module..."
    modprobe -r f2fs
fi

echo "[INFO] Loading native f2fs..."
modprobe f2fs

# 4. 提前检查 procfs 是否注册成功
if [[ ! -d /proc/fs/f2fs ]]; then
    echo "[ERROR] /proc/fs/f2fs does not exist!"
    exit 1
fi

echo "Using native F2FS"

# 4. 格式化：会清空设备所有数据
echo "WARNING: ALL DATA ON $DEV WILL BE ERASED"
read -r -p "Continue? [y/Y]: " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || exit 1

mkfs.f2fs -f -O extra_attr,compression "$DEV"

# 5. 挂载原生 F2FS
mkdir -p "$MNT"

mount -t f2fs \
  -o "mode=lfs,background_gc=off,nodiscard,compress_algorithm=$ALGO,compress_log_size=2,compress_mode=fs,compress_extension=*" \
  "$DEV" "$MNT"

findmnt -T "$MNT" -o SOURCE,FSTYPE,OPTIONS > "${OUT}_mount.txt"
cat "${OUT}_mount.txt"

# 确保使用的是原生 F2FS
FSTYPE=$(findmnt -n -o FSTYPE --target "$MNT")
[[ "$FSTYPE" == "f2fs" ]] || {
    echo "ERROR: Expected f2fs, got $FSTYPE"
    exit 1
}

test -r "$PROC"

# 6. 创建目标目录
mkdir -p "$MNT/data"

# 7. 写入前统计
sync

BEFORE=$(proc_blocks)

echo "Before: proc=$BEFORE"

# 8. 写入数据集
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

# 9. 确保压缩写回完成
sync

# 10. 写入后统计
AFTER=$(proc_blocks)

echo "After: proc=$AFTER"

# 11. 计算空间占用
USED=$((AFTER - BEFORE))
BYTES=$((USED * 4096))

echo "============================"
echo "System:         F2FS-Comp"
echo "Dataset:        $DATASET"
echo "Algorithm:      $ALGO"
echo "Before blocks:  $BEFORE"
echo "After blocks:   $AFTER"
echo "Physical blocks:$USED"
echo "Physical bytes: $BYTES"
echo "============================"

# 12. 抽查压缩属性
echo "Compression attribute check:"
find "$MNT/data" -type f -print -quit |
    xargs -r lsattr

# 13. 辅助压缩统计
SYS="/sys/fs/f2fs/$NAME"

if [[ -r "$SYS/compr_saved_block" ]]; then
    echo "F2FS compressed saved blocks:"
    cat "$SYS/compr_saved_block"
fi

# 14. 保存实验数据
echo "dataset,algorithm,system,before,after,used_blocks,physical_bytes" \
  > "${OUT}.csv"

echo "$DATASET,$ALGO,F2FS-Comp,$BEFORE,$AFTER,$USED,$BYTES" \
  >> "${OUT}.csv"

echo "Saved: ${OUT}.csv"

# 保留挂载状态，方便检查文件和 dmesg
# 检查结束后手动 umount "$MNT"
