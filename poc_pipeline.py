#!/usr/bin/env python3
"""
PoC: pipeline OCR multi-bon (segmentare-întâi) — validat pe poza de test cu 6 bonuri.
Utilizare: python3 poc_pipeline.py <imagine>
Dependențe: pip install pillow pytesseract  (+ tesseract-ocr, tesseract-ocr-ron)
"""
import sys, re, json, datetime
from PIL import Image
import pytesseract
from pytesseract import Output

# ============ 1. OCR cu detecție de orientare ============
def ocr_words(img):
    best = None
    for rot in (0, 90, 180, 270):
        r = img.rotate(rot, expand=True) if rot else img
        r = r.resize((int(r.width*1.5), int(r.height*1.5)), Image.LANCZOS)
        d = pytesseract.image_to_data(r, lang='ron+eng', config='--psm 11', output_type=Output.DICT)
        words = [dict(text=d['text'][i].strip(), x=d['left'][i], y=d['top'][i],
                      w=d['width'][i], h=d['height'][i])
                 for i in range(len(d['text']))
                 if d['text'][i].strip() and int(d['conf'][i]) >= 20]
        score = sum(len(w['text']) for w in words)
        if best is None or score > best[0]:
            best = (score, rot, words)
    print(f"[OCR] orientare aleasă: {best[1]}°, {len(best[2])} cuvinte")
    return best[2]

# ============ 2. Segmentare: XY-cut recursiv pe box-uri de CUVINTE ============
def xycut(ws, out, minx, miny):
    if len(ws) < 10:
        out.append(ws); return
    def best_gap(axis):
        ivs = sorted(((w['x'], w['x']+w['w']) if axis=='x' else (w['y'], w['y']+w['h'])) for w in ws)
        merged = [list(ivs[0])]
        for a, b in ivs[1:]:
            if a <= merged[-1][1] + 2: merged[-1][1] = max(merged[-1][1], b)
            else: merged.append([a, b])
        gaps = [(merged[i+1][0]-merged[i][1], (merged[i][1]+merged[i+1][0])/2) for i in range(len(merged)-1)]
        return max(gaps) if gaps else (0, None)
    gx, sx = best_gap('x'); gy, sy = best_gap('y')
    if gx < minx and gy < miny:
        out.append(ws); return
    if gx/minx >= gy/miny:
        L = [w for w in ws if w['x']+w['w']/2 < sx]; R = [w for w in ws if w['x']+w['w']/2 >= sx]
    else:
        L = [w for w in ws if w['y']+w['h']/2 < sy]; R = [w for w in ws if w['y']+w['h']/2 >= sy]
    xycut(L, out, minx, miny); xycut(R, out, minx, miny)

def bbox(c):
    return (min(w['x'] for w in c), min(w['y'] for w in c),
            max(w['x']+w['w'] for w in c), max(w['y']+w['h'] for w in c))

def text_of(c):
    return ' '.join(w['text'] for w in sorted(c, key=lambda w: (w['y'], w['x']))).upper()

HEADER_ANCHOR = re.compile(r'(NUMAR|WOMAR|NOMAR)\s+BON|COD\s+FISCAL|COD\s+IDENTIFICARE')

def merge_fragments(parts, mh):
    """unește fragmente antet/corp din aceeași coloană; nu unește 2 antete"""
    def xoverlap(a, b):
        ax0, _, ax1, _ = bbox(a); bx0, _, bx1, _ = bbox(b)
        inter = min(ax1, bx1) - max(ax0, bx0)
        return inter / min(ax1-ax0, bx1-bx0) if inter > 0 else 0
    merged = [list(p) for p in parts]
    changed = True
    while changed:
        changed = False
        for i in range(len(merged)):
            for j in range(i+1, len(merged)):
                a, b = merged[i], merged[j]
                _, ay0, _, ay1 = bbox(a); _, by0, _, by1 = bbox(b)
                vgap = max(by0-ay1, ay0-by1, 0)
                two_headers = HEADER_ANCHOR.search(text_of(a)) and HEADER_ANCHOR.search(text_of(b))
                if xoverlap(a, b) > 0.45 and vgap < mh*7 and not (two_headers and vgap > mh*3):
                    merged[i] = a + b; del merged[j]; changed = True; break
            if changed: break
    return merged

def split_by_anchors(c):
    """un bon are exact un antet — dacă un cluster are >=2, taie între ele"""
    ws = sorted(c, key=lambda w: (w['y'], w['x']))
    ys = []
    for idx, w in enumerate(ws):
        if re.match(r'^(NUMAR|WOMAR|NOMAR)[.,;:]?$', w['text'].upper()):
            nxt = ' '.join(x['text'].upper() for x in ws[idx+1:idx+3])
            if 'BON' in nxt: ys.append(w['y'])
    ys.sort()
    if len(ys) < 2: return [c]
    bounds = [ys[i] - 40 for i in range(1, len(ys))]
    parts = [[] for _ in range(len(bounds)+1)]
    for w in c:
        k = 0
        for bi, b in enumerate(bounds):
            if w['y'] >= b: k = bi + 1
        parts[k].append(w)
    return [p for p in parts if len(p) >= 10]

def segment(words):
    hs = sorted(w['h'] for w in words); mh = hs[len(hs)//2]
    parts = []; xycut(words, parts, mh*1.0, mh*1.5)
    parts = [p for p in parts if len(p) >= 8]
    merged = merge_fragments(parts, mh)
    final = []
    for c in merged:
        final.extend(split_by_anchors(c))
    final = [c for c in final if len(c) >= 14]
    final.sort(key=lambda c: (bbox(c)[0]//500, bbox(c)[1]))
    return final

# ============ 3. Extracție hardened per bon ============
def to_lines(c, ytol=16):
    srt = sorted(c, key=lambda w: (w['y'], w['x']))
    out = []; cur = [srt[0]]
    for w in srt[1:]:
        if abs(w['y'] - cur[0]['y']) < ytol: cur.append(w)
        else: out.append(cur); cur = [w]
    out.append(cur)
    return [' '.join(x['text'] for x in sorted(l, key=lambda w: w['x'])) for l in out]

def valid_cui(c):
    if not c.isdigit() or not (4 <= len(c) <= 10): return False   # MIN 4, nu 2!
    key = "753217532"; cr = c[::-1]; kr = key[::-1]
    s = sum(int(cr[i]) * int(kr[i-1]) for i in range(1, len(cr)) if i-1 < len(kr))
    ctrl = (s * 10) % 11
    return (0 if ctrl == 10 else ctrl) == int(cr[0])

SUBS = {'O':'0','Q':'0','D':'0','I':'1','L':'1','|':'1','Z':'2','S':'5','B':'8','G':'6','@':'0'}
def repair(s): return ''.join(SUBS.get(ch, ch) for ch in s.upper())

BUYER   = re.compile(r'CLIENT|CUMPARATOR|BENEF|CNP')
CUI_CTX = re.compile(r'(?:COD\s*FISCAL|COD\s*IDENTIFICARE\s*FISCALA|C\.?\s*[I1]\.?\s*F|CUI)\s*[.:]?\s*(R[O0Q])?\s*[.:]?\s*([A-Z0-9@]{4,10})', re.I)
RO_CUI  = re.compile(r'\bR[O0]\s?([0-9OQDILSZB@]{4,10})\b')

def extract_cui(lns, buyer_cui=None):
    cands = []
    for l in lns:
        if BUYER.search(l.upper()): continue
        cands += [m.group(2) for m in CUI_CTX.finditer(l)]
        cands += [m.group(1) for m in RO_CUI.finditer(l.upper())]
    # 1) direct
    for c in cands:
        d = re.sub(r'\D', '', repair(c))
        if valid_cui(d) and d != buyer_cui: return d, False, []
    # 2) reparare ghidată de checksum -> candidați de verificat la ANAF
    anaf_cands = []
    for c in cands:
        d = re.sub(r'\D', '', repair(c))
        if len(d) < 4: continue
        for x in '0123456789':
            if valid_cui(d + x): anaf_cands.append(d + x)          # cifră finală lipsă
        for pos in range(len(d)):
            for x in '0123456789':
                v = d[:pos] + x + d[pos+1:]
                if v != d and valid_cui(v): anaf_cands.append(v)   # o cifră citită greșit
    anaf_cands = [c for c in dict.fromkeys(anaf_cands) if c != buyer_cui]
    return (anaf_cands[0] if anaf_cands else None), True, anaf_cands

def extract_number(lns):
    for l in lns:
        m = re.search(r'(?:NUMAR|WOMAR|NOMAR)\s+BON\s+FISCAL\s*[:;.]?\s*(\d{1,6})', l, re.I)
        if m: return m.group(1)
    for l in lns:
        m = re.search(r'\bBF\.?\s*[:;.]?\s*(\d{1,6})', l, re.I)
        if m: return m.group(1)
    return None

def extract_date(lns):
    for l in lns:
        for m in re.finditer(r'\b(\d{1,2})\s?[./-]\s?(\d{1,2})\s?[./-]\s?(2\d{3})\b', repair(l)):
            d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
            if d > 31: d = d % 10  # 81 -> 1 (confuzie 8/0)
            if 1 <= d <= 31 and 1 <= mo <= 12 and 2020 <= y <= 2030:
                return f"{d:02d}.{mo:02d}.{y}"
    return None

def extract_company(lns):
    for l in lns[:6]:
        if re.search(r'\bS\.?R\.?L\.?\b|\bS\.?A\.?\b', l):
            return re.sub(r'\s+', ' ', l).strip()
    return None

BLACKLIST = re.compile(r'RC\s*:|AUTOR|NR\.?\s*CARD|TRX|CNP|C\.?I\.?F|TELEFON|POS\b|EJTRZ|ID\s*UNIC', re.I)
AMT = re.compile(r'(?<![\d%])(\d{1,5})\s?[.,]\s?(\d{2})(?!\d)')
def amounts_in(l):
    if BLACKLIST.search(l): return []
    return [float(f"{m.group(1)}.{m.group(2)}") for m in AMT.finditer(l)]

def valid_rates(ds):
    """Cote TVA România în funcție de data documentului (Legea 141/2025)."""
    if not ds: return [21.0, 11.0, 19.0, 9.0, 5.0]
    d, m, y = map(int, ds.split('.'))
    dt = datetime.date(y, m, d)
    if dt >= datetime.date(2025, 8, 1):
        r = [21.0, 11.0]
        if dt <= datetime.date(2026, 7, 31): r.append(9.0)  # doar locuinte, tranzitoriu
        return r
    return [19.0, 9.0, 5.0]

def extract_fin(lns, ds):
    rates_ok = valid_rates(ds)
    rates = []
    for l in lns:
        for m in re.finditer(r'TVA\s+[A-D]?\s*[-=]?\s*(\d{1,2})[.,]?\d{0,2}\s*%', l.upper()):
            r = float(m.group(1))
            if r in rates_ok and r not in rates: rates.append(r)
    vat_line = None
    for l in lns:
        if 'TOTAL TVA' in l.upper():
            vals = amounts_in(l)
            if vals: vat_line = vals[-1]
    total_line = None
    for l in lns:
        u = l.upper()
        if 'TOTAL' in u and 'SUBTOTAL' not in u and 'TVA' not in u:
            vals = [v for v in amounts_in(l) if v > 1]
            if vals: total_line = max(vals); break
    if total_line is None:
        for l in lns:
            if re.search(r'^\s*CARD\b|PLATA\s+CARD', l.upper()):
                vals = [v for v in amounts_in(l) if v > 1]
                if vals: total_line = max(vals); break
    warns = []; verified = False
    r = rates[0] if rates else 21.0
    allv = [v for l in lns for v in amounts_in(l)]
    def consistent(t, v): return abs(v - t * r / (100 + r)) <= 0.06
    total, vat = total_line, vat_line
    if total and vat and consistent(total, vat):
        verified = True
    elif vat and not (total and consistent(total, vat)):
        t_calc = round(vat * (100 + r) / r, 2)
        match = [v for v in allv if abs(v - t_calc) <= 0.06]
        if match:
            if total and abs(total - match[0]) > 0.06:
                warns.append(f"Total corectat matematic din TVA: {total} -> {match[0]}")
            total = match[0]; verified = True
        elif total:
            vat = round(total * r / (100 + r), 2); warns.append("TVA recalculat din total")
    elif total and vat is None:
        vat = round(total * r / (100 + r), 2); warns.append("TVA calculat matematic din total")
    base = round(total - vat, 2) if (total and vat is not None) else None
    return total, vat, base, (rates or None), verified, warns

def suggest_account(lns, comp):
    t = (' '.join(lns) + ' ' + (comp or '')).upper()
    if re.search(r'MOTORINA|BENZINA|GPL|DIESEL|OMV|PETROM|\bMOL\b|ROMPETROL|GAZ SRL', t):
        return "6022 / 3022 combustibili", "TVA deductibila 50% daca vehiculul nu e exclusiv economic (art. 298 CF)"
    if re.search(r'PARFUMERIE|DOUGLAS|SEPHORA|CADOU', t):
        return "623 protocol / 6588", "protocol: deductibilitate limitata"
    if re.search(r'RESTAURANT|CATERING|CAFENEA|PIZZA', t):
        return "623 protocol", "mancare 11% / alcool 21%"
    return "628 / 604", None

# ============ 4. ANAF v9 (batch, cu fuzzy match pe denumire) ============
def anaf_verify_batch(cui_list, company_hints, today=None):
    """POST https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva
    payload: [{"cui": "...", "data": "YYYY-MM-DD"}, ...]  (max ~100, 1 req/s)
    raspuns v9: found[i].date_generale.{cui,denumire,adresa}, found[i].inregistrare_scop_Tva.scpTVA
    Alege candidatul al carui 'denumire' se potriveste fuzzy cu antetul OCR."""
    import urllib.request
    today = today or datetime.date.today().isoformat()
    payload = json.dumps([{"cui": c, "data": today} for c in cui_list]).encode()
    req = urllib.request.Request(
        "https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva",
        data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
    except Exception as e:
        return {}
    out = {}
    for f in data.get("found", []):
        dg = f.get("date_generale", {})
        out[str(dg.get("cui"))] = dict(
            denumire=dg.get("denumire"), adresa=dg.get("adresa"),
            scpTVA=f.get("inregistrare_scop_Tva", {}).get("scpTVA"))
    return out

# ============ MAIN ============
def run(path, buyer_cui="30630040"):
    img = Image.open(path).convert('RGB')
    words = ocr_words(img)
    receipts = segment(words)
    print(f"[SEG] {len(receipts)} bonuri detectate\n")
    results = []
    for i, c in enumerate(receipts):
        lns = to_lines(c)
        ds = extract_date(lns)
        cui, cui_verif, anaf_cands = extract_cui(lns, buyer_cui)
        total, vat, base, rates, math_ok, warns = extract_fin(lns, ds)
        res = dict(bon=i, firma=extract_company(lns), cui=cui,
                   cui_de_verificat_anaf=anaf_cands or ([cui] if cui else []),
                   numar=extract_number(lns), data=ds, total=total,
                   cote=rates, tva=vat, baza=base, validat_matematic=math_ok,
                   cont=suggest_account(lns, extract_company(lns))[0],
                   avertismente=warns)
        results.append(res)
        print(json.dumps(res, ensure_ascii=False, indent=1))
    return results

if __name__ == '__main__':
    run(sys.argv[1] if len(sys.argv) > 1 else 'test.png')
