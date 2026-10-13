
#!/usr/bin/env bash
set -euo pipefail

ENWIK9=/home/lch/work/compress/data/enwik9_raw/enwik9
FDROID=/home/lch/work/compress/data/fdriod/fdroid_raw
SILESIA=/home/lch/work/compress/data/silesia/silesia_raw
LINUX_KERNEL=/home/lch/work/compress/data/linux_kernel/linux_kernel_raw

RESULT_DIR=/home/lch/work/compress/fig1_results
mkdir -p "$RESULT_DIR"

python3 - "$ENWIK9" "$FDROID" "$SILESIA" "$LINUX_KERNEL" "$RESULT_DIR/original_dataset_sizes.csv" <<'PY'
import csv
import os
import stat
import subprocess
import sys
from pathlib import Path

BLOCK = 4096

def inspect(name, src):
    path = Path(src)
    if not path.exists():
        raise SystemExit(f"ERROR: data source does not exist: {path}")

    if path.is_file():
        paths = [path]
    elif path.is_dir():
        paths = (Path(folder) / fn
                 for folder, _, names in os.walk(path, followlinks=False)
                 for fn in names)
    else:
        raise SystemExit(f"ERROR: not a regular file or directory: {path}")

    count = apk_count = logical = rounded = symlink_count = 0
    for f in paths:
        if f.is_symlink():
            symlink_count += 1
            continue
        info = f.stat()
        if not stat.S_ISREG(info.st_mode):
            continue
        count += 1
        apk_count += f.suffix.lower() == '.apk'
        logical += info.st_size
        rounded += ((info.st_size + BLOCK - 1) // BLOCK) * BLOCK

    du_output = subprocess.check_output(
        ['du', '-s', '-B1', '--', str(path)], text=True
    )
    source_du = int(du_output.split()[0])

    if symlink_count:
        print(f"WARNING: {name}: {symlink_count} symbolic links excluded from file-size sums")

    return {
        'dataset': name,
        'files': count,
        'apk_files': apk_count,
        'logical_bytes': logical,
        'theoretical_uncompressed_data_bytes_4k': rounded,
        'source_du_allocated_bytes': source_du,
    }

rows = [
    inspect('enwik9', sys.argv[1]),
    inspect('fdroid', sys.argv[2]),
    inspect('silesia', sys.argv[3]),
    inspect('linux_kernel', sys.argv[4]),
]

with open(sys.argv[5], 'w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)

for row in rows:
    print(f"\nDataset: {row['dataset']}")
    print(f"  Files:                       {row['files']}")
    print(f"  APK files:                   {row['apk_files']}")
    print(f"  Original logical bytes:      {row['logical_bytes']:,}  ({row['logical_bytes']/1048576:.3f} MiB)")
    print(f"  4KiB-rounded data bytes:     {row['theoretical_uncompressed_data_bytes_4k']:,}  ({row['theoretical_uncompressed_data_bytes_4k']/1048576:.3f} MiB)")
    print(f"  Source du allocated bytes:   {row['source_du_allocated_bytes']:,}  ({row['source_du_allocated_bytes']/1048576:.3f} MiB)")

print(f"\nCSV saved: {sys.argv[5]}")
PY
