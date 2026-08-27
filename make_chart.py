#!/c1/apps/python3/3.13.3/bin/python3.13

# /usr/bin/python3.12

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# Color used functionally: distinguishing write/read is the one place it
# earns its keep in this document. Muted, print-safe tones -- not a
# rainbow, not saturated, nothing decorative.

plt.rcParams.update({
    "font.family": "serif",
    "font.size": 10,
})

placements = ["Single node\n(4 tasks sharing)", "4 nodes\n(4 tasks/node, 16 total)", "4 nodes\n(1 task/node, 4 total)"]
write_vals = [294, 111, 861]
read_vals = [292, 241, 1580]

x = np.arange(len(placements))
width = 0.32

WRITE_COLOR = "#4C72B0"   # muted blue
READ_COLOR = "#DD8452"    # muted orange

fig, ax = plt.subplots(figsize=(6.3, 3.6))
bars_w = ax.bar(x - width/2, write_vals, width, label="Write", color=WRITE_COLOR, edgecolor="black", linewidth=0.6)
bars_r = ax.bar(x + width/2, read_vals, width, label="Read", color=READ_COLOR, edgecolor="black", linewidth=0.6)

ax.set_ylabel("MiB/s per task")
ax.set_xticks(x)
ax.set_xticklabels(placements)
ax.legend(frameon=False, loc="upper left")
ax.spines["top"].set_visible(False)
ax.spines["right"].set_visible(False)

for bars in (bars_w, bars_r):
    for b in bars:
        h = b.get_height()
        ax.annotate(f"{h:,.0f}", xy=(b.get_x() + b.get_width()/2, h),
                    xytext=(0, 3), textcoords="offset points",
                    ha="center", va="bottom", fontsize=8.5)

ax.set_ylim(0, 1750)
fig.tight_layout()
fig.savefig("placement_chart.pdf")
print("saved")

