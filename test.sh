#!/usr/bin/env bash
set -u
set -o pipefail

# P4 whole-pair GC validation (fixed mountpoint detection)
#
# Usage:
#   sudo ./validate_p4_gc_v2.sh <hidden_blkaddr> <anchor_nid> <anchor_ofs>
#
# Example:
#   sudo ./validate_p4_gc_v2.sh 235902984 5 32
#
# Optional overrides:
#   DEV=/dev/nvme1n1
#   MNT=/home/lch/work/compress/alice/test_mount
#   SRC=/tmp/copack_parts

DEV="${DEV:-/dev/nvme1n1}"
MNT="${MNT:-/home/lch/work/compress/alice/test_mount}"
SRC="${SRC:-/tmp/copack_parts}"
FSTYPE="${FSTYPE:-cf2fs}"
DEVNAME="$(basename "$DEV")"
SYSFS="/sys/fs/cf2fs/${DEVNAME}"
MOUNT_OPTS="${MOUNT_OPTS:-background_gc=off,mode=lfs,compress_algorithm=lz4,compress_log_size=2,compress_mode=fs,compress_extension=*}"

if [ "$#" -ne 3 ]; then
    echo "Usage: sudo $0 <hidden_blkaddr> <anchor_nid> <anchor_ofs>"
    echo "Example: sudo $0 235902984 5 32"
    exit 2
fi

HIDDEN="$1"
EXPECT_NID="$2"
EXPECT_OFS="$3"
DUMP_OUT="/tmp/p4_hidden_${HIDDEN}.dump.txt"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root"
    exit 2
fi

if [ ! -d "$SRC" ]; then
    echo "ERROR: source directory does not exist: $SRC"
    exit 2
fi

mkdir -p "$MNT"

print_sep()
{
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

is_exact_mountpoint()
{
    mountpoint -q "$MNT"
}

show_mount()
{
    if is_exact_mountpoint; then
        findmnt -rn -M "$MNT" -o TARGET,SOURCE,FSTYPE,OPTIONS
    else
        echo "$MNT is NOT a mountpoint"
    fi
}

verify_survivors()
{
    label="$1"
    bad=0
    missing=0
    total=0

    if ! is_exact_mountpoint; then
        echo "ERROR [$label]: $MNT is not mounted as a filesystem mountpoint"
        return 2
    fi

    file_list="$(find "$MNT" -maxdepth 1 -type f -name 'p*' -print | sort)"
    if [ -z "$file_list" ]; then
        echo "ERROR [$label]: no surviving p* files under $MNT"
        return 2
    fi

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        total=$((total + 1))
        b="$(basename "$f")"
        src="$SRC/$b"

        if [ ! -f "$src" ]; then
            echo "MISSING SOURCE [$label]: $src"
            missing=$((missing + 1))
            bad=$((bad + 1))
            continue
        fi

        if ! cmp -s "$src" "$f"; then
            echo "MISMATCH [$label]: $b"
            bad=$((bad + 1))
        fi
    done <<EOF_FILES
$file_list
EOF_FILES

    echo "[$label] total=$total bad=$bad missing_source=$missing"
    [ "$bad" -eq 0 ]
}

mount_cf2fs_off()
{
    if is_exact_mountpoint; then
        src="$(findmnt -rn -M "$MNT" -o SOURCE)"
        fs="$(findmnt -rn -M "$MNT" -o FSTYPE)"
        if [ "$fs" != "$FSTYPE" ]; then
            echo "ERROR: $MNT is already mounted as $fs from $src, expected $FSTYPE"
            return 1
        fi
        return 0
    fi

    echo "Mounting $DEV at $MNT with background_gc=off ..."
    mount -t "$FSTYPE" -o "$MOUNT_OPTS" "$DEV" "$MNT"
}

umount_cf2fs()
{
    if is_exact_mountpoint; then
        sync
        umount "$MNT"
    else
        echo "NOTE: $MNT already unmounted"
    fi
}

extract_first_hex()
{
    grep -oE '0x[0-9a-fA-F]+' | head -n 1
}

parse_hex_or_empty()
{
    token="$1"
    if [ -z "$token" ]; then
        echo ""
        return
    fi
    echo $((token))
}

overall_fail=0

print_sep "0. Stop urgent GC and show exact mountpoint state"

if [ -e "$SYSFS/gc_urgent" ]; then
    echo 0 > "$SYSFS/gc_urgent" || true
    echo "gc_urgent=$(cat "$SYSFS/gc_urgent" 2>/dev/null || echo unknown)"
else
    echo "NOTE: $SYSFS/gc_urgent not present; continuing."
fi

if ! is_exact_mountpoint; then
    echo "ERROR: $MNT is not currently mounted."
    exit 2
fi

show_mount
sync

print_sep "1. Current-mount correctness"

if verify_survivors "warm"; then
    echo "PASS: warm cmp"
else
    echo "FAIL: warm cmp"
    overall_fail=1
fi

print_sep "2. Cold-cache correctness"

sync
echo 3 > /proc/sys/vm/drop_caches
sleep 1

if verify_survivors "cold"; then
    echo "PASS: cold cmp"
else
    echo "FAIL: cold cmp"
    overall_fail=1
fi

print_sep "3. Remount persistence correctness"

umount_cf2fs || {
    echo "ERROR: umount failed"
    exit 2
}

mount_cf2fs_off || {
    echo "ERROR: remount failed"
    exit 2
}

show_mount

if verify_survivors "remount"; then
    echo "PASS: remount cmp"
else
    echo "FAIL: remount cmp"
    overall_fail=1
fi

print_sep "4. Hidden-block SSA anchor"

umount_cf2fs || {
    echo "ERROR: umount before dump.f2fs failed"
    exit 2
}

echo "dump.f2fs -d 1 -b $HIDDEN $DEV"
dump.f2fs -d 1 -b "$HIDDEN" "$DEV" >"$DUMP_OUT" 2>&1
dump_rc=$?

echo "dump output: $DUMP_OUT"

if [ "$dump_rc" -ne 0 ]; then
    echo "FAIL: dump.f2fs returned $dump_rc"
    overall_fail=1
else
    grep -E 'Block_addr|Segno|Offset|SUM\.nid|SUM\.ofs_in_node|SUM\.version|NAT\.blkaddr|NAT\.ino|FS Userdata Area|Obsolete block' "$DUMP_OUT" || true

    block_hex="$(grep -m1 'Block_addr' "$DUMP_OUT" | extract_first_hex || true)"
    nid_hex="$(grep -m1 'SUM\.nid' "$DUMP_OUT" | extract_first_hex || true)"
    ofs_hex="$(grep -m1 'SUM\.ofs_in_node' "$DUMP_OUT" | extract_first_hex || true)"

    block_dec="$(parse_hex_or_empty "$block_hex")"
    nid_dec="$(parse_hex_or_empty "$nid_hex")"
    ofs_dec="$(parse_hex_or_empty "$ofs_hex")"

    echo
    echo "Parsed:"
    echo "  block=$block_dec (expected $HIDDEN)"
    echo "  SUM.nid=$nid_dec (expected $EXPECT_NID)"
    echo "  SUM.ofs_in_node=$ofs_dec (expected $EXPECT_OFS)"

    metadata_ok=1

    if [ -z "$block_dec" ] || [ "$block_dec" -ne "$HIDDEN" ]; then
        echo "FAIL: Block_addr mismatch or not parsed"
        metadata_ok=0
    fi

    if [ -z "$nid_dec" ] || [ "$nid_dec" -ne "$EXPECT_NID" ]; then
        echo "FAIL: SUM.nid mismatch or not parsed"
        metadata_ok=0
    fi

    if [ -z "$ofs_dec" ] || [ "$ofs_dec" -ne "$EXPECT_OFS" ]; then
        echo "FAIL: SUM.ofs_in_node mismatch or not parsed"
        metadata_ok=0
    fi

    if grep -qi 'Obsolete block' "$DUMP_OUT"; then
        echo "FAIL: relocated hidden block is reported obsolete"
        metadata_ok=0
    fi

    if [ "$metadata_ok" -eq 1 ]; then
        echo "PASS: hidden block SSA anchor matches P4 log"
    else
        overall_fail=1
    fi
fi

print_sep "5. Restore mount with background_gc=off"

if mount_cf2fs_off; then
    show_mount
else
    echo "WARNING: validation finished but automatic remount failed"
    overall_fail=1
fi

print_sep "FINAL"

if [ "$overall_fail" -eq 0 ]; then
    echo "P4 VALIDATION PASS"
    echo "  warm cmp    : PASS"
    echo "  cold cmp    : PASS"
    echo "  remount cmp : PASS"
    echo "  hidden SSA  : PASS"
    exit 0
else
    echo "P4 VALIDATION FAILED -- inspect messages above"
    exit 1
fi
