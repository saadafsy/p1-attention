"""Draw a block-coloured floorplan from scripts/fpga_floorplan.tcl output.

    python3 scripts/fpga_floorplan.py <placement.csv> <out.png> "<title>" group=regex ...

Each group is a label and a regex on the cell path; the first match colours the
site. Unused sites are drawn light grey so the shape of the part is visible.
"""
import csv, re, sys
from collections import Counter, defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

src, out, title, *spec = sys.argv[1:]
groups = [(g.split("=", 1)[0], re.compile(g.split("=", 1)[1])) for g in spec]
palette = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e", "#17becf", "#8c564b", "#e377c2"]
sites, used = {}, defaultdict(Counter)
for row in csv.reader(open(src)):
    if row[0] == "S":
        sites[row[1]] = (row[2], int(row[3]), int(row[4]))
    elif row[0] == "C" and row[1] in sites or row[0] == "C":
        site, cell = row[1], ",".join(row[2:])
        label = next((n for n, rx in groups if rx.search(cell)), "other")
        used[site][label] += 1
fig, ax = plt.subplots(figsize=(9, 9), dpi=150)
fig.patch.set_facecolor("white")
def marker(t):
    return ("s", 9) if t.startswith("SLICE") else (("D", 30) if t.startswith("DSP") else ("s", 40))
for name, (t, x, y) in sites.items():
    m, sz = marker(t)
    ax.scatter(x, y, s=sz, marker=m, color="#e6e6e6", linewidths=0)
colors = {n: palette[i % len(palette)] for i, (n, _) in enumerate(groups)}
colors["other"] = "#555555"
counts = Counter()
for site, c in used.items():
    if site not in sites:
        continue
    t, x, y = sites[site]
    label = c.most_common(1)[0][0]
    counts[label] += 1
    m, sz = marker(t)
    ax.scatter(x, y, s=sz, marker=m, color=colors[label], linewidths=0)
ax.set_aspect("equal"); ax.axis("off")
ax.set_title(title, fontsize=12, loc="left")
handles = [Patch(color=colors[n], label=f"{n} ({counts[n]} sites)") for n, _ in groups if counts[n]]
if counts["other"]:
    handles.append(Patch(color=colors["other"], label=f"other ({counts['other']} sites)"))
handles.append(Patch(color="#e6e6e6", label="unused"))
ax.legend(handles=handles, loc="upper left", bbox_to_anchor=(1.0, 1.0), frameon=False, fontsize=9)
fig.savefig(out, bbox_inches="tight", facecolor="white")
print(f"wrote {out}: " + ", ".join(f"{k}={v}" for k, v in counts.most_common()))
