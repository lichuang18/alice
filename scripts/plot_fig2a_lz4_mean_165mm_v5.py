#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fig.2(a), LZ4, mean of 5 measurements.
Old-layout version with a top 2x4 legend.
Preserves the previous overall geometry style and does NOT use tight bbox.
"""
from pathlib import Path
import matplotlib as mpl
import matplotlib.pyplot as plt

mpl.rcParams.update({
    'font.family': 'serif',
    'font.serif': ['Times New Roman', 'Tinos', 'Liberation Serif'],
    'font.size': 7,
    'axes.labelsize': 7,
    'xtick.labelsize': 7,
    'ytick.labelsize': 7,
    'legend.fontsize': 7,
    'axes.linewidth': 0.55,
    'pdf.fonttype': 42,
    'ps.fonttype': 42,
    'svg.fonttype': 'none',
    'xtick.major.size': 2.5,
    'ytick.major.size': 2.5,
    'xtick.major.width': 0.55,
    'ytick.major.width': 0.55,
    'savefig.facecolor': 'white',
})

THREADS = [1, 2, 4, 8]
DATA = {'enwik9': {'f2fscomp': {'write': [239.105717, 255.013638, 249.246755, 251.972952],
                         'seqread': [1011.284211, 1504.783647, 2812.799635, 5576.899803],
                         'randread': [6907.237751, 13319.158094, 25795.437269, 44222.558108]},
            'copack': {'write': [232.893673, 251.047425, 243.316993, 252.902972],
                       'seqread': [1124.873047, 1765.592153, 3128.590717, 5540.885634],
                       'randread': [7402.275968, 13934.124613, 25480.477213, 44177.432661]}},
 'fdroid': {'f2fscomp': {'write': [519.44697, 458.514766, 452.190432, 420.378181],
                         'seqread': [1333.14284, 1597.757276, 2350.579912, 2953.644399],
                         'randread': [10940.612748, 20945.308251, 40584.592178, 67220.269525]},
            'copack': {'write': [488.103397, 443.37579, 433.307725, 430.55244],
                       'seqread': [1562.8568, 1788.924844, 2656.284467, 3169.222378],
                       'randread': [10272.737016, 19349.089348, 38519.92375, 65845.080453]}},
 'silesia': {'f2fscomp': {'write': [263.01096, 249.286505, 245.405698, 240.623637],
                          'seqread': [1053.676113, 1142.173997, 1816.638929, 2307.131112],
                          'randread': [5117.300263, 10157.71615, 20373.020213, 41821.395343]},
             'copack': {'write': [257.008942, 244.523764, 243.510652, 237.952877],
                        'seqread': [955.66889, 1262.815433, 2185.035666, 2332.811529],
                        'randread': [4857.628422, 9925.483593, 21847.086978, 40185.946865]}},
 'linux_kernel': {'f2fscomp': {'write': [240.204103, 142.97762, 141.259136, 137.189508],
                               'seqread': [48.084431, 44.152956, 45.173757, 45.181169],
                               'randread': [4747.165182, 4493.014193, 4761.860126, 4807.647931]},
                  'copack': {'write': [241.498943, 141.103728, 140.410752, 134.740796],
                             'seqread': [47.156143, 44.533598, 44.895911, 44.931021],
                             'randread': [4692.594851, 4533.682122, 4711.277268, 4793.775325]}}}

DATASETS = ['enwik9', 'fdroid', 'silesia', 'linux_kernel']
NAMES = {'enwik9': 'enwik9', 'fdroid': 'F-Droid', 'silesia': 'Silesia', 'linux_kernel': 'Linux Kernel'}
MARKERS = {'enwik9':'o', 'fdroid':'s', 'silesia':'^', 'linux_kernel':'D'}
COLORS = dict(zip(DATASETS, plt.rcParams['axes.prop_cycle'].by_key()['color'][:4]))
SYSTEMS = [('f2fscomp', 'F2FS-Comp'), ('copack', 'CoPack')]

WIDTH_MM = 165.0
HEIGHT_MM = WIDTH_MM * 5.0 / 18.0
PANELS = [
    ('write', 'Sequential Write (MiB/s)'),
    ('seqread', 'Sequential Read (GiB/s)'),
    ('randread', 'Random Read (K IOPS)'),
]


def make_figure():
    fig, axes = plt.subplots(1, 3, figsize=(WIDTH_MM / 25.4, HEIGHT_MM / 25.4), dpi=300)
    # Preserve the general wide-panel feel; reserve a compact band for a 2x4 top legend.
    fig.subplots_adjust(left=0.078, right=0.992, bottom=0.185, top=0.755, wspace=0.21)

    legend_handles = []
    legend_labels = []
    seen = set()

    for ax, (mode, ylabel) in zip(axes, PANELS):
        for dataset in DATASETS:
            for system, system_label in SYSTEMS:
                color = COLORS[dataset]
                copack = system == 'copack'
                label = f'{NAMES[dataset]} · {system_label}'
                line, = ax.plot(
                    THREADS,
                    [v / (1024 if mode == 'seqread' else 1000 if mode == 'randread' else 1)
                     for v in DATA[dataset][system][mode]],
                    color=color,
                    linestyle='-',
                    linewidth=0.85,
                    marker=MARKERS[dataset],
                    markersize=3.1,
                    markerfacecolor=color if copack else 'white',
                    markeredgecolor=color,
                    markeredgewidth=0.85,
                    label=label,
                    zorder=3 if copack else 2,
                )
                if label not in seen:
                    seen.add(label)
                    legend_handles.append(line)
                    legend_labels.append(label)
        ax.set_ylabel(ylabel, labelpad=2)
        ax.set_xlabel('Threads', labelpad=1.6)
        ax.set_xticks(THREADS)
        ax.set_xlim(0.75, 8.25)
        ax.set_ylim(bottom=0)
        ax.grid(True, linewidth=0.35, alpha=0.25)
        ax.set_axisbelow(True)
        ax.tick_params(axis='both', direction='out', pad=1.8)

    fig.legend(
        legend_handles,
        legend_labels,
        loc='upper center',
        bbox_to_anchor=(0.5, 0.935),
        ncol=4,
        fontsize=7,
        handlelength=1.25,
        handletextpad=0.38,
        columnspacing=0.8,
        labelspacing=0.35,
        borderpad=0.18,
        frameon=True,
        framealpha=0.85,
        edgecolor='0.78',
        markerscale=1.0,
    )
    return fig


def main():
    fig = make_figure()
    output_dir = Path(__file__).resolve().parent
    base = output_dir / 'fig2a_lz4_mean_165mm_v5'
    for ext in ('pdf', 'svg', 'png'):
        path = base.with_suffix('.' + ext)
        fig.savefig(path, dpi=600 if ext == 'png' else 300)
        print(path)
    plt.close(fig)


if __name__ == '__main__':
    main()
