import re, sys
sys.path.insert(0, "/home/claude/replay")
from words import W

class Box:
    def __init__(self, t, x, y, w, h):
        self.text, self.x, self.y, self.w, self.h = t, float(x), float(y), float(w), float(h)

WORDS = [Box(*t) for t in W]

# ---------- port fidel din ReceiptSegmenterV2.swift ----------

def median_h(ws):
    hs = sorted(w.h for w in ws)
    return max(hs[len(hs) // 2], 4.0)

def lines_with_y(words):
    if not words: return []
    mh = median_h(words)
    sw = sorted(words, key=lambda w: (w.y + w.h / 2, w.x))
    lines, centers = [], []
    for w in sw:
        c = w.y + w.h / 2
        if centers and abs(c - centers[-1]) < mh * 0.7:
            lines[-1].append(w)
            n = len(lines[-1])
            centers[-1] = (centers[-1] * (n - 1) + c) / n
        else:
            lines.append([w]); centers.append(c)
    return [(y, " ".join(x.text for x in sorted(ws, key=lambda q: q.x)))
            for y, ws in zip(centers, lines)]

def group_lines(words):
    return [t for _, t in lines_with_y(words)]

def bbox(c):
    return (min(w.x for w in c), min(w.y for w in c),
            max(w.x + w.w for w in c), max(w.y + w.h for w in c))

def xycut(ws, min_gx, min_gy, out):
    if len(ws) < 10:
        out.append(ws); return
    def best_gap(axis):
        iv = sorted((w.x, w.x + w.w) if axis == "x" else (w.y, w.y + w.h) for w in ws)
        merged = [list(iv[0])]
        for a, b in iv[1:]:
            if a <= merged[-1][1] + 2: merged[-1][1] = max(merged[-1][1], b)
            else: merged.append([a, b])
        best = None
        for i in range(len(merged) - 1):
            g = merged[i + 1][0] - merged[i][1]
            if best is None or g > best[0]:
                best = (g, (merged[i][1] + merged[i + 1][0]) / 2)
        return best
    gx, gy = best_gap("x"), best_gap("y")
    sx = gx[0] if gx else 0
    sy = gy[0] if gy else 0
    if sx < min_gx and sy < min_gy:
        out.append(ws); return
    if sx / min_gx >= sy / min_gy and gx:
        split = gx[1]
        xycut([w for w in ws if w.x + w.w / 2 < split], min_gx, min_gy, out)
        xycut([w for w in ws if w.x + w.w / 2 >= split], min_gx, min_gy, out)
    elif gy:
        split = gy[1]
        xycut([w for w in ws if w.y + w.h / 2 < split], min_gx, min_gy, out)
        xycut([w for w in ws if w.y + w.h / 2 >= split], min_gx, min_gy, out)
    else:
        out.append(ws)

CTX = re.compile(r"(?:COD\s*FISCAL|COD\s*IDENTIFICARE\s*FISCALA|\bC\.?\s*I\.?\s*F\b|\bCUI\b)\s*[.:]?\s*(?:R[O0])?\s*([0-9OQDILSZB@]{4,12})", re.I)
EXCL = re.compile(r"CLIENT|CNP|CUMPARATOR|BENEF", re.I)
BON = re.compile(r"NUMAR\s*BON", re.I)
REPAIR = str.maketrans({"O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "|": "1",
                        "Z": "2", "S": "5", "B": "8", "G": "6", "@": "0"})

def merchant_cui_hints(cluster):
    out = set()
    for line in group_lines(cluster):
        if EXCL.search(line): continue
        for m in CTX.finditer(line):
            digits = "".join(ch for ch in m.group(1).upper().translate(REPAIR) if ch.isdigit())
            if len(digits) >= 4: out.add(digits)
    return out

def looks_like_receipt(c):
    if merchant_cui_hints(c): return True
    return any(BON.search(l) for l in group_lines(c))

def merge_fragments(parts, mh):
    merged = [list(p) for p in parts]
    changed = True
    while changed:
        changed = False
        for i in range(len(merged)):
            done = False
            for j in range(i + 1, len(merged)):
                a, b = bbox(merged[i]), bbox(merged[j])
                inter = min(a[2], b[2]) - max(a[0], b[0])
                minw = min(a[2] - a[0], b[2] - b[0])
                xo = inter / minw if inter > 0 and minw > 0 else 0
                vgap = max(b[1] - a[3], a[1] - b[3], 0)
                if looks_like_receipt(merged[i]) and looks_like_receipt(merged[j]): continue
                ca, cb = merchant_cui_hints(merged[i]), merchant_cui_hints(merged[j])
                if ca and cb and ca.isdisjoint(cb): continue
                if xo > 0.5 and vgap < mh * 4:
                    merged[i].extend(merged[j]); del merged[j]
                    changed = True; done = True; break
            if done: break
    return merged

ANCHOR = re.compile(r"NUMAR\s*BON|COD\s*FISCAL|COD\s*IDENTIFICARE\s*FISCALA|\bC\.?\s*I\.?\s*F\b|\bCUI\b", re.I)

def split_by_anchors(cluster, mh, anchor_rx=ANCHOR):
    lines = lines_with_y(cluster)
    ys = sorted(y for y, t in lines if anchor_rx.search(t) and not EXCL.search(t))
    groups = []
    for y in ys:
        if groups and y - groups[-1] < mh * 12: continue
        groups.append(y)
    if len(groups) < 2: return [cluster]
    cuts = []
    for k in range(len(groups) - 1):
        lo, hi = groups[k], groups[k + 1]
        seq = [lo] + sorted(y for y, _ in lines if lo < y < hi) + [hi]
        best_gap, best_cut = -1, (lo + hi) / 2
        for m in range(len(seq) - 1):
            if seq[m + 1] - seq[m] > best_gap:
                best_gap = seq[m + 1] - seq[m]
                best_cut = (seq[m] + seq[m + 1]) / 2
        cuts.append(best_cut)
    parts = [[] for _ in range(len(cuts) + 1)]
    for w in cluster:
        c = w.y + w.h / 2
        k = 0
        for ci, cut in enumerate(cuts):
            if c >= cut: k = ci + 1
        parts[k].append(w)
    return [p for p in parts if len(p) >= 10]

def segment(words, anchor_rx=ANCHOR):
    if not words: return []
    mh = median_h(words)
    parts = []
    xycut(words, mh * 1.0, mh * 1.5, parts)
    parts = [p for p in parts if len(p) >= 8]
    merged = merge_fragments(parts, mh)
    merged = [q for p in merged for q in split_by_anchors(p, mh, anchor_rx)]
    merged = [p for p in merged if len(p) >= 12]
    return sorted(merged, key=lambda c: (int(bbox(c)[0] // 400), bbox(c)[1]))

# ---------- identificarea bonului din fiecare cluster ----------

MARKERS = {
    "Magistral-114": "114", "MOL-337": "337", "Turist-1076": "1076",
    "Magistral-112": "112", "ROG-0084": "0084",
}
def describe(clusters, title):
    print("=" * 30, title, f"-> {len(clusters)} clustere")
    for i, c in enumerate(clusters):
        b = bbox(c)
        text = " | ".join(group_lines(c))
        bons = re.findall(r"(?:NUMAR\s*BON\s*FISCAL:|BON\s*FISCAL:)\s*(\d{3,4})", text)
        cuis = sorted(merchant_cui_hints(c))
        totals = re.findall(r"1[48][0-9][.,]\d\d|61[13][.,]\d\d", text)
        names = [n for n in ["MAGISTRAL", "PETROLEUM", "DOUGLAS", "TURIST", "EUiISFIO"] if n in text]
        print(f"  C{i}: x[{b[0]:.0f}-{b[2]:.0f}] y[{b[1]:.0f}-{b[3]:.0f}] "
              f"n={len(c)} nume={names} bon={bons} cui={cuis} sume={sorted(set(totals))}")

describe(segment(WORDS), "STAREA ACTUALA (algoritmul din telefon)")

# ---------- loader pentru dump-ul de la GET /debug_clusters ----------
def load_debug_clusters(path):
    """Incarca JSON-ul salvat de la http://IP:8000/debug_clusters si intoarce
    toate cuvintele (reunite din clustere) ca lista de Box, per orientare."""
    import json
    data = json.load(open(path, encoding="utf-8"))
    by_turns = {}
    for c in data.get("clusters", []):
        by_turns.setdefault(c.get("turns", 0), []).extend(
            Box(w["t"], w["x"], w["y"], w["w"], w["h"]) for w in c.get("words", []))
    return by_turns

if __name__ == "__main__" and len(sys.argv) > 1:
    for turns, ws in load_debug_clusters(sys.argv[1]).items():
        describe(segment(ws), f"replay debug_clusters (turns={turns})")
