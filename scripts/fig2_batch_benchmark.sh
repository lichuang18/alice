#!/usr/bin/env bash
# Fig.2(a) real-data benchmark batch runner for native F2FS-Comp and CoPack.
# One C benchmark for both filesystems. Always operate on a dedicated test disk.
set -Eeuo pipefail

ROOT=/home/lch/work/compress/alice
DEV=/dev/nvme1n1
MNT="$ROOT/test_mount"
C_SOURCE="$ROOT/scripts/fig2_realdata_bench.c"
RESULT_ROOT=/home/lch/work/compress/fig2_results

# Override from command line environment, e.g. THREADS='1 4' ALGOS='lz4'.
THREADS="${THREADS:-1 2 4 8}"
SYSTEMS="${SYSTEMS:-f2fscomp copack}"
ALGOS="${ALGOS:-lz4 lzo zstd}"
DATASETS="${DATASETS:-enwik9 fdroid silesia linux_kernel}"

# 1 = reformat for EVERY system/dataset/algorithm/thread run (paper-quality).
# 0 = reformat per system/algorithm/thread and reuse the mount across datasets
#     (QUICK EXPLORATION ONLY: remove+sync does not reset F2FS segment state).
REFORMAT_EACH_DATASET="${REFORMAT_EACH_DATASET:-1}"
PER_FILE_CSV="${PER_FILE_CSV:-0}"

usage() {
    cat <<'EOF'
Usage:
  sudo ./fig2_batch_benchmark.sh [--plan]

Defaults: threads=1 2 4 8, filesystems=f2fscomp copack,
          algorithms=lz4 lzo zstd, datasets=enwik9 fdroid silesia linux_kernel.

Examples:
  ./fig2_batch_benchmark.sh --plan
  THREADS='1' ALGOS='lz4' DATASETS='enwik9' ./fig2_batch_benchmark.sh
  REFORMAT_EACH_DATASET=0 ./fig2_batch_benchmark.sh  # exploratory only

WARNING: running without --plan repeatedly ERASES /dev/nvme1n1.
EOF
}

PLAN=0
case "${1:-}" in
    --plan) PLAN=1; [[ $# == 1 ]] || { usage; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    '') [[ $# == 0 ]] || { usage; exit 2; } ;;
    *) usage; exit 2 ;;
esac

[[ "$REFORMAT_EACH_DATASET" == 0 || "$REFORMAT_EACH_DATASET" == 1 ]] || {
    echo '[ERROR] REFORMAT_EACH_DATASET must be 0 or 1' >&2; exit 2;
}
[[ "$PER_FILE_CSV" == 0 || "$PER_FILE_CSV" == 1 ]] || {
    echo '[ERROR] PER_FILE_CSV must be 0 or 1' >&2; exit 2;
}

# Always use arrays for safe iteration over the simple allow-listed run dimensions.
read -r -a WORKER_LIST <<< "$THREADS"
read -r -a SYSTEM_LIST <<< "$SYSTEMS"
read -r -a ALGO_LIST <<< "$ALGOS"
read -r -a DATASET_LIST <<< "$DATASETS"
(( ${#WORKER_LIST[@]} && ${#SYSTEM_LIST[@]} && ${#ALGO_LIST[@]} && ${#DATASET_LIST[@]} )) || {
    echo '[ERROR] Each test dimension must be nonempty' >&2; exit 2;
}
for n in "${WORKER_LIST[@]}"; do
    [[ "$n" =~ ^(1|2|4|8)$ ]] || { echo "[ERROR] Unsupported worker count: $n" >&2; exit 2; }
done
for s in "${SYSTEM_LIST[@]}"; do
    [[ "$s" == f2fscomp || "$s" == copack ]] || { echo "[ERROR] Unknown filesystem: $s" >&2; exit 2; }
done
for a in "${ALGO_LIST[@]}"; do
    [[ "$a" == lz4 || "$a" == lzo || "$a" == zstd ]] || { echo "[ERROR] Unknown codec: $a" >&2; exit 2; }
done
for d in "${DATASET_LIST[@]}"; do
    [[ "$d" == enwik9 || "$d" == fdroid || "$d" == silesia || "$d" == linux_kernel ]] || {
        echo "[ERROR] Unknown dataset: $d" >&2; exit 2;
    }
done

source_path() {
    case "$1" in
        enwik9)       printf '%s\n' /home/lch/work/compress/data/enwik9_raw/enwik9 ;;
        fdroid)       printf '%s\n' /home/lch/work/compress/data/fdriod/fdroid_raw ;;
        silesia)      printf '%s\n' /home/lch/work/compress/data/silesia/silesia_raw ;;
        linux_kernel) printf '%s\n' /home/lch/work/compress/data/linux_kernel/linux_kernel_raw ;;
    esac
}

TOTAL=$(( ${#WORKER_LIST[@]} * ${#SYSTEM_LIST[@]} * ${#ALGO_LIST[@]} * ${#DATASET_LIST[@]} ))
if [[ "$REFORMAT_EACH_DATASET" == 1 ]]; then
    FORMATS=$TOTAL
else
    FORMATS=$(( ${#WORKER_LIST[@]} * ${#SYSTEM_LIST[@]} * ${#ALGO_LIST[@]} ))
fi

echo "[PLAN] $TOTAL dataset runs; $((TOTAL * 3)) measurements (write/seqread/randread); $FORMATS formats"
echo "[PLAN] Systems: $SYSTEMS | Codecs: $ALGOS | Workers: $THREADS | Datasets: $DATASETS"
echo "[PLAN] Format each dataset: $REFORMAT_EACH_DATASET"
if ((PLAN)); then
    i=0
    for t in "${WORKER_LIST[@]}"; do
        for s in "${SYSTEM_LIST[@]}"; do
            for a in "${ALGO_LIST[@]}"; do
                for d in "${DATASET_LIST[@]}"; do
                    ((++i))
                    printf '  %3d/%d  %-9s  %-12s  %-5s  %d threads\n' "$i" "$TOTAL" "$s" "$d" "$a" "$t"
                done
            done
        done
    done
    exit 0
fi

[[ "$EUID" == 0 ]] || { echo '[ERROR] Run as root (needed for mkfs and cold-cache tests)' >&2; exit 1; }
[[ -b "$DEV" ]] || { echo "[ERROR] Not a block device: $DEV" >&2; exit 1; }
[[ -f "$C_SOURCE" ]] || { echo "[ERROR] Missing C benchmark: $C_SOURCE" >&2; exit 1; }
for d in "${DATASET_LIST[@]}"; do
    raw=$(source_path "$d")
    [[ -e "$raw" ]] || { echo "[ERROR] Missing dataset: $raw" >&2; exit 1; }
done
if ! mountpoint -q /dev/shm; then
    echo '[ERROR] /dev/shm must be mounted (RAM-backed source staging)' >&2; exit 1
fi

# Confirm the entire destructive batch exactly once before the first mkfs.
echo "WARNING: ALL DATA on $DEV will be ERASED ($FORMATS formatting operations)."
read -r -p 'Continue the entire batch? [y/Y]: ' CONFIRM
[[ "$CONFIRM" == y || "$CONFIRM" == Y ]] || exit 0

mkdir -p "$RESULT_ROOT" "$MNT"
RUN_TAG="$(date +%Y%m%d_%H%M%S)_$$"
OUT="$RESULT_ROOT/fig2_batch_$RUN_TAG"
mkdir -m 0755 "$OUT"
RAW_CSV="$OUT/raw_summary.csv"
TABLE_CSV="$OUT/fig2_results.csv"
BIN="$ROOT/scripts/fig2_realdata_bench"
STAGE=""
MOUNTED=0

# Produces an easy-to-plot CSV even if the batch stops early.
make_results_csv() {
    [[ -s "$RAW_CSV" ]] || return 0
    python3 - "$RAW_CSV" "$TABLE_CSV" <<'PY'
import csv, sys
source, output = sys.argv[1:]
with open(source, newline='', encoding='utf8') as f:
    rows = list(csv.DictReader(f))
if not rows:
    sys.exit(0)
with open(output, 'w', newline='', encoding='utf8') as f:
    fieldnames = ['system', 'dataset', 'algorithm', 'workers', 'mode'] + [
        k for k in rows[0] if k not in ('label', 'mode')
    ]
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        system, suffix = row['label'].split('_', 1)
        dataset, algorithm, worker_text = suffix.rsplit('_', 2)
        writer.writerow({
            'system': system, 'dataset': dataset, 'algorithm': algorithm,
            'workers': worker_text.removeprefix('t'), 'mode': row['mode'],
            **{k: v for k, v in row.items() if k not in ('label', 'mode')},
        })
PY
}

finish() {
    rc=$?
    trap - EXIT
    set +e
    if ((MOUNTED)) && mountpoint -q "$MNT"; then
        sync -f "$MNT"
        umount "$MNT" || echo "[WARN] Failed to umount $MNT; check manually" >&2
    fi
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        rm -rf -- "$STAGE"
    fi
    make_results_csv || echo '[WARN] Failed to create formatted summary CSV' >&2
    if ((rc == 0)); then
        echo "[DONE] Benchmark completed: $OUT"
    else
        echo "[ERROR] Stopped with exit $rc. Partial results: $OUT" >&2
    fi
    exit "$rc"
}
trap finish EXIT

# Compile the single userspace test binary. CoPack module built only if selected.
echo '[BUILD] Compiling the C benchmark...'
gcc -O2 -Wall -Wextra -pthread "$C_SOURCE" -o "$BIN"
if [[ " $SYSTEMS " == *' copack '* ]]; then
    echo '[BUILD] Building cf2fs.ko...'
    (cd "$ROOT" && make -j16)
fi

# Safety: only our test mount may be unmounted automatically; refuse other mounts.
if mountpoint -q "$MNT"; then
    echo "[CLEAN] Unmounting previous $MNT..."
    sync -f "$MNT"
    umount "$MNT"
fi
if findmnt -rn -S "$DEV" | grep .; then
    echo "[ERROR] Device still mounted elsewhere: $DEV" >&2; exit 1
fi
if findmnt -rn -t f2fs,cf2fs | grep .; then
    echo '[ERROR] Another F2FS/cf2fs filesystem is mounted; do not unload active modules' >&2
    findmnt -t f2fs,cf2fs
    exit 1
fi

# Stage input ONCE. Source reads never touch another disk during timed writes.
STAGE="$(mktemp -d /dev/shm/copack_fig2_stage.XXXXXXXX)"
for d in "${DATASET_LIST[@]}"; do
    raw=$(source_path "$d")
    echo "[STAGE] $d: $raw -> $STAGE/$d"
    cp -a --reflink=never -- "$raw" "$STAGE/$d"
done

load_system() {
    local system="$1"
    [[ "$MOUNTED" == 0 ]] || { echo '[ERROR] Refusing module reload on mounted filesystem' >&2; return 1; }
    if lsmod | grep '^cf2fs '; then
        echo '[MODULE] rmmod cf2fs'
        rmmod cf2fs
    fi
    if lsmod | grep '^f2fs '; then
        echo '[MODULE] modprobe -r f2fs'
        modprobe -r f2fs
    fi
    # cf2fs.ko needs symbols from native f2fs on this machine.
    echo '[MODULE] modprobe f2fs'
    modprobe f2fs
    if [[ "$system" == copack ]]; then
        echo '[MODULE] insmod cf2fs.ko'
        insmod "$ROOT/cf2fs.ko"
    else
        [[ -d /proc/fs/f2fs ]] || {
            echo '[ERROR] Native F2FS procfs root did not register' >&2; return 1;
        }
    fi
}

mount_fresh() {
    local system="$1" algo="$2"
    local fstype=f2fs
    [[ "$system" == copack ]] && fstype=cf2fs
    [[ "$MOUNTED" == 0 ]] || { echo '[ERROR] Cannot mkfs a mounted test filesystem' >&2; return 1; }
    if findmnt -rn -S "$DEV" | grep .; then
        echo "[ERROR] Refusing to format a mounted device: $DEV" >&2
        return 1
    fi
    echo "[MKFS] $DEV ($system / $algo)"
    mkfs.f2fs -f -O extra_attr,compression "$DEV"
    # mount -t "$fstype" \
    #     -o "mode=lfs,background_gc=off,nodiscard,compress_algorithm=$algo,compress_log_size=2,compress_mode=fs,compress_extension=*" \
    #     "$DEV" "$MNT"
    mount -t "$fstype" \
        -o "mode=lfs,background_gc=off,nodiscard,compress_algorithm=$algo,compress_log_size=2,compress_mode=fs,compress_extension=*,compress_cache" \
        "$DEV" "$MNT"
        
    MOUNTED=1
    local actual
    actual="$(findmnt -n -o FSTYPE --target "$MNT")"
    [[ "$actual" == "$fstype" ]] || { echo "[ERROR] Unexpected fs type: $actual" >&2; return 1; }
    findmnt -T "$MNT" -o SOURCE,FSTYPE,OPTIONS
    if [[ "$system" == f2fscomp && ! -r "/proc/fs/f2fs/$(basename "$DEV")/segment_info" ]]; then
        echo '[ERROR] Missing native F2FS proc SIT (module registration conflict?)' >&2
        return 1
    fi
    if [[ "$system" == copack && ! -r "/sys/fs/cf2fs/$(basename "$DEV")/physical_data_blocks" ]]; then
        echo '[WARN] CoPack physical_data_blocks sysfs unavailable; performance measurement can still run' >&2
    fi
}

unmount_clean() {
    if ((MOUNTED)); then
        sync -f "$MNT"
        umount "$MNT"
        MOUNTED=0
    fi
}

run_mode() {
    local system="$1" d="$2" algo="$3" t="$4" mode="$5" target="$6" prefix="$7"
    local label="${system}_${d}_${algo}_t${t}"
    local logfile="${prefix}_${mode}.log"
    local args=(
        --mode "$mode" --source "$STAGE/$d" --target "$target"
        --threads "$t" --device "$DEV" --label "$label"
        --summary-csv "$RAW_CSV"
    )
    if [[ "$mode" != write ]]; then args+=(--cold --seed 2027); fi
    if [[ "$PER_FILE_CSV" == 1 ]]; then
        args+=(--per-file-csv "${prefix}_${mode}_files.csv")
    fi
    echo "[BENCH] $system $d $algo t=$t $mode"
    "$BIN" "${args[@]}" 2>&1 | tee "$logfile"
}

IDX=0
for t in "${WORKER_LIST[@]}"; do
    for system in "${SYSTEM_LIST[@]}"; do
        load_system "$system"
        for algo in "${ALGO_LIST[@]}"; do
            if [[ "$REFORMAT_EACH_DATASET" == 0 ]]; then
                mount_fresh "$system" "$algo"
            fi
            for d in "${DATASET_LIST[@]}"; do
                ((++IDX))
                echo
                echo "======== [$IDX/$TOTAL] system=$system algo=$algo dataset=$d workers=$t ========"
                if [[ "$REFORMAT_EACH_DATASET" == 1 ]]; then
                    mount_fresh "$system" "$algo"
                fi
                # In quick mode each dataset gets its own temporary subtree and is
                # removed after full sync. This does not reset SIT allocation history.
                target="$MNT/fig2_${d}"
                prefix="$OUT/${system}_${d}_${algo}_t${t}"
                findmnt -T "$MNT" -o SOURCE,FSTYPE,OPTIONS > "${prefix}_mount.txt"
                sync -f "$MNT"
                run_mode "$system" "$d" "$algo" "$t" write "$target" "$prefix"
                # The C reader separately syncfs+drop_caches for each read mode;
                # never use the write-warmed page cache as a read benchmark.
                run_mode "$system" "$d" "$algo" "$t" seqread "$target" "$prefix"
                run_mode "$system" "$d" "$algo" "$t" randread "$target" "$prefix"
                sync -f "$MNT"
                if [[ "$REFORMAT_EACH_DATASET" == 1 ]]; then
                    unmount_clean
                else
                    rm -rf -- "$target"
                    sync -f "$MNT"
                fi
                make_results_csv
            done
            if [[ "$REFORMAT_EACH_DATASET" == 0 ]]; then
                unmount_clean
            fi
        done
    done
done

echo "[RESULT] Combined CSV: $TABLE_CSV"
