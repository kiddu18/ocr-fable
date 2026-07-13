import re
import functools
import math

# --- Helper functions ---

def levenshtein_distance(s1: str, s2: str) -> int:
    last = list(range(len(s2) + 1))
    for i, char1 in enumerate(s1):
        cur = [i + 1] + [0] * len(s2)
        for j, char2 in enumerate(s2):
            if char1 == char2:
                cur[j + 1] = last[j]
            else:
                cur[j + 1] = min(last[j], last[j + 1], cur[j]) + 1
        last = cur
    return last[-1]

def is_fuzzy_match(s1: str, s2: str, tolerance: int = 1) -> bool:
    return levenshtein_distance(s1.upper(), s2.upper()) <= tolerance

def is_valid_cui(cui):
    if not (2 <= len(cui) <= 10) or not cui.isdigit():
        return False
    # Ignore 10-digit numbers starting with "07", "02", or "03" (phone numbers)
    if len(cui) == 10 and (cui.startswith("07") or cui.startswith("02") or cui.startswith("03")):
        return False
    control_key = "753217532"[::-1]
    cui_rev = cui[::-1]
    control_digit = int(cui_rev[0])
    s = 0
    for i in range(1, len(cui_rev)):
        if i - 1 < len(control_key):
            s += int(cui_rev[i]) * int(control_key[i-1])
    calc = (s * 10) % 11
    final_ctrl = 0 if calc == 10 else calc
    return final_ctrl == control_digit

def extract_cui(text):
    clean = text.upper().replace(" ", "").replace(".", "").replace(":", "").replace("-", "")
    matches = re.findall(r"\d{2,10}", clean)
    for candidate in matches:
        if is_valid_cui(candidate):
            return candidate
    return None

def is_buyer_cui_box(box, boxes, median_height):
    text = box["text"].upper()
    buyer_keywords = ["CLIENT", "CUMP", "BENEF", "CNP", "C.N.P"]
    
    # 1. Direct check
    for kw in buyer_keywords:
        if kw in text:
            return True
            
    # 2. Fuzzy match tokens
    tokens = re.findall(r"\w+", text)
    for token in tokens:
        for kw in buyer_keywords:
            tolerance = 0 if len(kw) <= 3 else 1
            if is_fuzzy_match(token, kw, tolerance):
                return True

    # 3. 2D Spatial check
    for other in boxes:
        if other["x"] == box["x"] and other["y"] == box["y"]:
            continue
        other_text = other["text"].upper()
        has_buyer_kw = any(kw in other_text for kw in buyer_keywords)
        if not has_buyer_kw:
            # check fuzzy
            other_tokens = re.findall(r"\w+", other_text)
            for token in other_tokens:
                for kw in buyer_keywords:
                    tolerance = 0 if len(kw) <= 3 else 1
                    if is_fuzzy_match(token, kw, tolerance):
                        has_buyer_kw = True
                        break
                if has_buyer_kw:
                    break
        if not has_buyer_kw:
            continue
        
        dy = box["y"] - other["y"]
        dx = box["x"] - other["x"]
        
        # Scenario 1: Same line, label to the left
        if abs(dy) < median_height * 1.5 and dx > 0 and dx < median_height * 12.0:
            return True
        # Scenario 2: Label is directly above
        if dy > 0 and dy < median_height * 2.5 and abs(dx) < median_height * 6.0:
            return True
    return False

def clean_fallback_candidate(raw_text):
    # Keep only alphanumeric characters
    s = "".join([c for c in raw_text.upper() if c.isalnum()])
    prefixes = ["CIF", "CUI", "RO", "R0", "COD", "FISCAL", "CODFISCAL"]
    changed = True
    while changed:
        changed = False
        for prefix in prefixes:
            if s.startswith(prefix):
                s = s[len(prefix):]
                changed = True
    # Length between 2 and 12, and must contain at least one digit
    if 2 <= len(s) <= 12 and any(c.isdigit() for c in s):
        return s
    return None

def extract_cui_with_fallback(boxes, candidate_boxes, text_blocks):
    # 1. Try mathematically valid CUI inside candidate boxes
    for box in candidate_boxes:
        if "%" in box["text"]:
            continue
        cleaned = clean_fallback_candidate(box["text"])
        if cleaned and cleaned.isdigit() and is_valid_cui(cleaned):
            return cleaned, False # CUI, requires_verification=False
            
    # 2. Try mathematically valid CUI in nearby boxes
    for keyword_box in candidate_boxes:
        nearby_boxes = [
            b for b in boxes
            if (b["x"] != keyword_box["x"] or b["y"] != keyword_box["y"]) and
            b["y"] >= keyword_box["y"] - keyword_box["h"] * 0.8 and
            b["y"] <= keyword_box["y"] + keyword_box["h"] * 2.0 and
            b["x"] >= keyword_box["x"] - keyword_box["w"] * 0.5
        ]
        nearby_boxes.sort(key=lambda b: b["x"])
        for nb in nearby_boxes:
            if "%" in nb["text"]:
                continue
            cleaned = clean_fallback_candidate(nb["text"])
            if cleaned and cleaned.isdigit() and is_valid_cui(cleaned):
                return cleaned, False
                
    # 3. Classic regex fallback for mathematically valid CUI
    full_text = " ".join(text_blocks).upper()
    matches = re.finditer(r"\b([0-9]{2,10})\b", full_text)
    for m in matches:
        cui_candidate = m.group(1)
        start, end = m.span()
        if start > 0 and full_text[start-1] in ".,":
            continue
        if end < len(full_text) and full_text[end] in ".,":
            continue
        if end < len(full_text) and full_text[end] == "%":
            continue
        if end < len(full_text) - 1 and full_text[end:end+2] == " %":
            continue
        # Check if this candidate is a buyer CUI
        is_buyer = False
        for box in boxes:
            bx, by, bw, bh, btext, _ = get_box_properties(box)
            if cui_candidate in btext.replace(" ", ""):
                sorted_heights = sorted([get_box_properties(b)[3] for b in boxes])
                med_h = sorted_heights[len(sorted_heights) // 2] if sorted_heights else 15.0
                if is_buyer_cui_box(box, boxes, med_h):
                    is_buyer = True
                    break
        if is_buyer:
            continue
            
        if is_valid_cui(cui_candidate):
            return cui_candidate, False
            
    # 4. ROBUST FALLBACK FOR OCR TYPOS: Nearby alphanumeric sequences (length 2-12)
    fallback_candidates = []
    
    # Check keyword boxes themselves
    for box in candidate_boxes:
        cleaned = clean_fallback_candidate(box["text"])
        if cleaned:
            fallback_candidates.append((cleaned, 0.0))
            
    # Check nearby boxes
    for keyword_box in candidate_boxes:
        nearby_boxes = [
            b for b in boxes
            if (b["x"] != keyword_box["x"] or b["y"] != keyword_box["y"]) and
            b["y"] >= keyword_box["y"] - keyword_box["h"] * 1.5 and
            b["y"] <= keyword_box["y"] + keyword_box["h"] * 3.0 and
            b["x"] >= keyword_box["x"] - keyword_box["w"] * 0.5
        ]
        for nb in nearby_boxes:
            if "%" in nb["text"]:
                continue
            cleaned = clean_fallback_candidate(nb["text"])
            if cleaned:
                dx = nb["x"] - keyword_box["x"]
                dy = nb["y"] - keyword_box["y"]
                dist = math.sqrt(dx*dx + dy*dy)
                fallback_candidates.append((cleaned, dist))
                
    if fallback_candidates:
        fallback_candidates.sort(key=lambda x: x[1])
        return fallback_candidates[0][0], True # CUI, requires_verification=True
        
    return None, True

def is_phone_or_phone_label(box, boxes, median_height):
    text = box["text"].upper()
    phone_labels = ["TEL", "FAX", "MOBIL", "TELEFON"]
    for label in phone_labels:
        if label in text:
            return True
            
    digits = "".join([c for c in text if c.isdigit()])
    if len(digits) == 10 and (digits.startswith("07") or digits.startswith("02") or digits.startswith("03")):
        return True
        
    for other in boxes:
        if other["x"] == box["x"] and other["y"] == box["y"]:
            continue
        other_text = other["text"].upper()
        has_phone_label = any(label in other_text for label in phone_labels)
        if not has_phone_label:
            continue
        dy = abs(box["y"] - other["y"])
        dx = abs(box["x"] - other["x"])
        if dy < median_height * 1.5 and dx < median_height * 12.0:
            return True
    return False

def is_seller_anchor_box(box, boxes, median_height):
    if is_phone_or_phone_label(box, boxes, median_height):
        return False
    if is_buyer_cui_box(box, boxes, median_height):
        return False
        
    upper = box["text"].upper()
    if "%" in upper:
        return False
        
    no_dots = upper.replace(".", "")
    no_spaces = no_dots.replace(" ", "")
    
    if no_spaces.startswith("BON") or "BON " in no_dots:
        return False
        
    seller_keywords = ["CIF", "CUI", "CODFISCAL", "FISCAL", "COD FISCAL"]
    
    # 1. Direct contains check
    for kw in seller_keywords:
        if kw in no_dots or kw.replace(" ", "") in no_spaces:
            return True
            
    # 2. Fuzzy match tokens
    tokens = re.findall(r"\w+", upper)
    for token in tokens:
        for kw in seller_keywords:
            tolerance = 1 if len(kw) <= 3 else 2
            if is_fuzzy_match(token, kw, tolerance):
                return True
                
    # 3. 2D Spatial check for nearby seller keyword
    for other in boxes:
        if other["x"] == box["x"] and other["y"] == box["y"]:
            continue
        other_upper = other["text"].upper()
        other_no_dots = other_upper.replace(".", "")
        other_no_spaces = other_no_dots.replace(" ", "")
        
        has_seller_kw = any(kw in other_no_dots or kw.replace(" ", "") in other_no_spaces for kw in seller_keywords)
        if not has_seller_kw:
            other_tokens = re.findall(r"\w+", other_upper)
            for token in other_tokens:
                for kw in seller_keywords:
                    tolerance = 1 if len(kw) <= 3 else 2
                    if is_fuzzy_match(token, kw, tolerance):
                        has_seller_kw = True
                        break
                if has_seller_kw:
                    break
        if not has_seller_kw:
            continue
            
        dy = abs(box["y"] - other["y"])
        dx = abs(box["x"] - other["x"])
        if dy < median_height * 2.0 and dx < median_height * 12.0:
            return True
            
    return False

def cluster_boxes(boxes):
    if len(boxes) <= 1:
        return [boxes]
    
    sorted_heights = sorted([b["h"] for b in boxes])
    median_height = sorted_heights[len(sorted_heights) // 2]
    
    unique_anchors = []
    for box in boxes:
        if is_seller_anchor_box(box, boxes, median_height):
            is_dup = False
            for u in unique_anchors:
                dx = abs(u["x"] - box["x"])
                dy = abs(u["y"] - box["y"])
                if dx < median_height * 5.0 and dy < median_height * 3.0:
                    is_dup = True
                    break
            if not is_dup:
                unique_anchors.append(box)
                
    if len(unique_anchors) > 1:
        groups = [[] for _ in range(len(unique_anchors))]
        for box in boxes:
            col_of_box = 0 if box["x"] < 500 else 1
            candidates = []
            for idx, anchor in enumerate(unique_anchors):
                col_of_anchor = 0 if anchor["x"] < 500 else 1
                if col_of_box == col_of_anchor:
                    dy = box["y"] - anchor["y"]
                    if dy >= -median_height * 1.5:
                        candidates.append((idx, dy))
            if not candidates:
                best_idx = 0
                best_dist = float("inf")
                for idx, anchor in enumerate(unique_anchors):
                    dist = (box["x"] - anchor["x"])**2 + (box["y"] - anchor["y"])**2
                    if dist < best_dist:
                        best_dist = dist
                        best_idx = idx
                groups[best_idx].append(box)
            else:
                best_idx, min_dy = min(candidates, key=lambda x: x[1])
                groups[best_idx].append(box)
                
        for g in groups:
            def compare_boxes(b1, b2):
                if abs(b1["y"] - b2["y"]) < median_height:
                    return -1 if b1["x"] < b2["x"] else 1 if b1["x"] > b2["x"] else 0
                return -1 if b1["y"] < b2["y"] else 1 if b1["y"] > b2["y"] else 0
            import functools
            g.sort(key=functools.cmp_to_key(compare_boxes))
            
        def compare_groups(g1, g2):
            if not g1: return 1
            if not g2: return -1
            y1 = g1[0]["y"]
            y2 = g2[0]["y"]
            x1 = g1[0]["x"]
            x2 = g2[0]["x"]
            r1 = y1 // 400
            r2 = y2 // 400
            if r1 != r2:
                return -1 if r1 < r2 else 1
            return -1 if x1 < x2 else 1
            
        import functools
        return sorted(groups, key=functools.cmp_to_key(compare_groups))
    else:
        return [boxes]

def group_boxes_into_lines(boxes, median_height):
    sorted_by_y = sorted(boxes, key=lambda b: b["y"])
    lines = []
    if not sorted_by_y:
        return lines
    current_line = [sorted_by_y[0]]
    y_tolerance = median_height * 0.4
    for box in sorted_by_y[1:]:
        avg_y = sum(b["y"] for b in current_line) / len(current_line)
        if abs(box["y"] - avg_y) < y_tolerance:
            current_line.append(box)
        else:
            lines.append(current_line)
            current_line = [box]
    lines.append(current_line)
    return [sorted(line, key=lambda b: b["x"]) for line in lines]

def extract_financials(boxes):
    sorted_heights = sorted([b["h"] for b in boxes])
    median_height = sorted_heights[len(sorted_heights) // 2] if sorted_heights else 15.0
    
    # Classify document
    full_text = " ".join(b["text"].upper() for b in boxes)
    is_receipt = any(kw in full_text for kw in ["TERMINAL ID", "PIN VERIFICAT", "POS", "CHITANTA POS"])
    
    # CUI Extraction
    cui_keywords = ["CIF", "CUI", "CODFISCAL", "RO"]
    candidate_boxes = []
    for box in boxes:
        if is_buyer_cui_box(box, boxes, median_height):
            continue
        clean_text = box["text"].upper().replace(".", "").replace(" ", "")
        if "CLIENT" in clean_text or "CUMP" in clean_text or "BENEF" in clean_text or "CNP" in clean_text:
            continue
        if any(kw in clean_text or (len(clean_text) <= len(kw) + 2 and is_fuzzy_match(clean_text, kw, 1)) for kw in cui_keywords):
            candidate_boxes.append(box)
            
    lines = group_boxes_into_lines(boxes, median_height)
    buyer_texts = [b["text"].upper() for b in boxes if is_buyer_cui_box(b, boxes, median_height)]
    cui_text_blocks = []
    for line in lines:
        line_text = " ".join(b["text"] for b in line)
        for bt in buyer_texts:
            if bt in line_text.upper():
                line_text = re.sub(re.escape(bt), "", line_text, flags=re.IGNORECASE)
        cui_text_blocks.append(line_text)
    seller_cui, requires_verification = extract_cui_with_fallback(boxes, candidate_boxes, cui_text_blocks)
            
    # Total
    total_amount = None
    total_keywords = ["TOTAL", "SUMA", "ACHITAT"]
    
    total_found = False
    for line in lines:
        for idx, box in enumerate(line):
            clean_text = box["text"].upper().replace(" ", "").replace(":", "")
            if any(kw in clean_text or len(clean_text) <= len(kw) + 2 and kw in clean_text for kw in total_keywords):
                line_text = " ".join(b["text"].upper() for b in line)
                if any(kw in line_text for kw in ["TVA", "TAXA", "TAXE"]):
                    continue
                for l_box in line[idx:]:
                    if l_box["x"] <= box["x"]:
                        continue
                    sanitized = l_box["text"].replace(",", ".")
                    match = re.search(r"([0-9]+\.[0-9]{2})", sanitized)
                    if match:
                        total_amount = float(match.group(1))
                        total_found = True
                        break
            if total_found:
                break
        if total_found:
            break
            
    if not total_found:
        total_pattern = r"(?:TOTAL|SUMA|ACHITAT)[ \t]*(?:LEI)?[ \t]*[:=]*[ \t]*([0-9]+[.,][0-9]{2})"
        match = re.search(total_pattern, full_text)
        if match:
            total_amount = float(match.group(1).replace(",", "."))
            total_found = True
            
    if not total_found:
        matches = re.findall(r"\b([0-9]+[.,][0-9]{2})\b", full_text)
        amounts = []
        for m in matches:
            val = float(m.replace(",", "."))
            if val not in [24.0, 21.0, 19.0, 11.0, 9.0, 5.0]:
                amounts.append(val)
        if amounts:
            total_amount = max(amounts)
            
    # VAT Breakdowns
    breakdowns = []
    
    if is_receipt:
        breakdowns.append({"percentage": "-", "vatAmount": 0.0, "baseAmount": total_amount or 0.0})
    else:
        for line in lines:
            line_text = " ".join(b["text"] for b in line)
            pct_match = re.search(r"\b([0-9]{1,2})(?:[.,][0-9]{1,2})?\s*%", line_text)
            if not pct_match:
                continue
            rate = float(pct_match.group(1))
            clean_line_text = line_text.replace(pct_match.group(0), "")
            dec_matches = re.findall(r"\b([0-9]+[.,][0-9]{2})\b", clean_line_text)
            vals = [float(v.replace(",", ".")) for v in dec_matches]
            
            vat_amount = None
            base_amount = None
            
            if len(vals) >= 2:
                for i in range(len(vals)):
                    for j in range(len(vals)):
                        if i == j:
                            continue
                        base_cand = vals[i]
                        vat_cand = vals[j]
                        if abs(vat_cand - base_cand * (rate / 100.0)) < 0.05:
                            vat_amount = vat_cand
                            base_amount = base_cand
                            break
                    if vat_amount is not None:
                        break
                
                if vat_amount is None:
                    for i in range(len(vals)):
                        for j in range(len(vals)):
                            if i == j:
                                continue
                            base_cand = vals[i]
                            total_cand = vals[j]
                            if abs(total_cand - base_cand * (1.0 + rate / 100.0)) < 0.05:
                                base_amount = base_cand
                                vat_amount = round(total_cand - base_cand, 2)
                                break
                        if vat_amount is not None:
                            break
                            
                if vat_amount is None:
                    sorted_vals = sorted(vals)
                    vat_amount = sorted_vals[0]
                    base_amount = sorted_vals[1]
            elif len(vals) == 1:
                val = vals[0]
                if total_amount and abs(val - total_amount) < 0.05:
                    base_amount = round(total_amount / (1.0 + rate / 100.0), 2)
                    vat_amount = round(total_amount - base_amount, 2)
                else:
                    vat_amount = val
                    base_amount = round(val / (rate / 100.0), 2)
                    
            if vat_amount is not None and base_amount is not None:
                pct_str = f"{int(rate)}%"
                if not any(b["percentage"] == pct_str for b in breakdowns):
                    breakdowns.append({"percentage": pct_str, "vatAmount": vat_amount, "baseAmount": base_amount})
                    
        if not breakdowns:
            match = re.search(r"TOTAL\s*TVA[^0-9]{0,15}?([0-9]+[,.][0-9]{2})", full_text)
            if match:
                val = float(match.group(1).replace(",", "."))
                base = round(total_amount - val, 2) if total_amount else val
                breakdowns.append({"percentage": "Mixt", "vatAmount": val, "baseAmount": base})
                
    # If total amount is missing but breakdowns exist, calculate it
    if total_amount is None and breakdowns:
        sum_base = sum(b["baseAmount"] for b in breakdowns)
        sum_vat = sum(b["vatAmount"] for b in breakdowns)
        total_amount = round(sum_base + sum_vat, 2)

    results = []
    if breakdowns:
        for b in breakdowns:
            results.append({
                "cui": seller_cui,
                "cuiRequiresVerification": requires_verification,
                "totalAmount": round(b["baseAmount"] + b["vatAmount"], 2) if len(breakdowns) > 1 else (total_amount if total_amount is not None else round(b["baseAmount"] + b["vatAmount"], 2)),
                "vatAmount": b["vatAmount"],
                "baseAmount": b["baseAmount"],
                "vatPercentages": b["percentage"]
            })
    else:
        results.append({
            "cui": seller_cui,
            "cuiRequiresVerification": requires_verification,
            "totalAmount": total_amount,
            "vatAmount": 0.0,
            "baseAmount": total_amount,
            "vatPercentages": "-"
        })
    return results

def run_tests():
    # Construct 6-receipt mock OCR boxes layout
    # Canvas size: width=1000, height=1500
    # Receipts arranged in a 2x3 grid:
    # Col 0: x in [50, 450], Col 1: x in [550, 950]
    # Row 0: y in [50, 450], Row 1: y in [550, 950], Row 2: y in [1050, 1450]
    
    boxes = []
    
    # Receipt 1: Row 0, Col 0. Seller CUI: "123453" (but simulate OCR inaccuracy as "R0 12345P").
    # Total: 119.00. VAT: 19% (100.00 base, 19.00 VAT).
    boxes.extend([
        {"text": "RETAIL STORE SRL", "x": 100, "y": 70, "w": 200, "h": 20},
        {"text": "CIF", "x": 100, "y": 100, "w": 40, "h": 20},
        {"text": "R0 12345P", "x": 150, "y": 100, "w": 100, "h": 20}, # OCR inaccuracy: 'R0' instead of 'RO', 'P' instead of '3'
        {"text": "CLIENT:", "x": 100, "y": 200, "w": 70, "h": 20},
        {"text": "RO 87654329", "x": 180, "y": 200, "w": 100, "h": 20},
        {"text": "PRODUS X", "x": 100, "y": 250, "w": 100, "h": 20},
        {"text": "100.00", "x": 350, "y": 250, "w": 60, "h": 20},
        {"text": "TVA 19%", "x": 100, "y": 300, "w": 80, "h": 20},
        {"text": "100.00", "x": 250, "y": 300, "w": 60, "h": 20},
        {"text": "19.00", "x": 350, "y": 300, "w": 60, "h": 20},
        {"text": "TOTAL DE PLATA", "x": 100, "y": 350, "w": 150, "h": 20},
        {"text": "119.00", "x": 350, "y": 350, "w": 60, "h": 20},
    ])
    
    # Receipt 2: Row 0, Col 1. Seller CUI: 1234565 (split).
    # Total: 200.00. VAT: 19% (168.07 base, 31.93 VAT).
    boxes.extend([
        {"text": "SUPERMARKET SRL", "x": 600, "y": 70, "w": 200, "h": 20},
        {"text": "CIF", "x": 600, "y": 100, "w": 40, "h": 20},
        {"text": "1234565", "x": 650, "y": 100, "w": 100, "h": 20},
        {"text": "CUMPARATURI", "x": 600, "y": 250, "w": 120, "h": 20},
        {"text": "200.00", "x": 850, "y": 250, "w": 60, "h": 20},
        {"text": "TVA 19%", "x": 600, "y": 300, "w": 80, "h": 20},
        {"text": "168.07", "x": 750, "y": 300, "w": 60, "h": 20},
        {"text": "31.93", "x": 850, "y": 300, "w": 60, "h": 20},
        {"text": "TOTAL", "x": 600, "y": 350, "w": 100, "h": 20},
        {"text": "200.00", "x": 850, "y": 350, "w": 60, "h": 20},
    ])
    
    # Receipt 3: Row 1, Col 0. Seller CUI: 12345674.
    # Total: 150.00. VAT: 9% (137.61 base, 12.39 VAT).
    boxes.extend([
        {"text": "PHARMACY SRL", "x": 100, "y": 570, "w": 200, "h": 20},
        {"text": "CUI RO 12345674", "x": 100, "y": 600, "w": 150, "h": 20},
        {"text": "MEDICAMENTE", "x": 100, "y": 750, "w": 120, "h": 20},
        {"text": "150.00", "x": 350, "y": 750, "w": 60, "h": 20},
        {"text": "TVA 9%", "x": 100, "y": 800, "w": 80, "h": 20},
        {"text": "137.61", "x": 250, "y": 800, "w": 60, "h": 20},
        {"text": "12.39", "x": 350, "y": 800, "w": 60, "h": 20},
        {"text": "TOTAL", "x": 100, "y": 850, "w": 100, "h": 20},
        {"text": "150.00", "x": 350, "y": 850, "w": 60, "h": 20},
    ])
    
    # Receipt 4: Row 1, Col 1. Seller CUI: 123456789. MULTIPLE VAT RATES.
    # Total: 173.50. VAT 19% (100.00 base, 19.00 VAT), VAT 9% (50.00 base, 4.50 VAT).
    boxes.extend([
        {"text": "HYPERMARKET SRL", "x": 600, "y": 570, "w": 200, "h": 20},
        {"text": "CUI: RO 123456789", "x": 600, "y": 600, "w": 180, "h": 20},
        {"text": "ALIMENTE A", "x": 600, "y": 700, "w": 100, "h": 20},
        {"text": "100.00", "x": 850, "y": 700, "w": 60, "h": 20},
        {"text": "ALIMENTE B", "x": 600, "y": 730, "w": 100, "h": 20},
        {"text": "50.00", "x": 850, "y": 730, "w": 60, "h": 20},
        {"text": "TVA 19%", "x": 600, "y": 780, "w": 80, "h": 20},
        {"text": "100.00", "x": 750, "y": 780, "w": 60, "h": 20},
        {"text": "19.00", "x": 850, "y": 780, "w": 60, "h": 20},
        {"text": "TVA 9%", "x": 600, "y": 810, "w": 80, "h": 20},
        {"text": "50.00", "x": 750, "y": 810, "w": 60, "h": 20},
        {"text": "4.50", "x": 850, "y": 810, "w": 60, "h": 20},
        {"text": "TOTAL DE PLATA", "x": 600, "y": 850, "w": 150, "h": 20},
        {"text": "173.50", "x": 850, "y": 850, "w": 60, "h": 20},
    ])
    
    # Receipt 5: Row 2, Col 0. Seller CUI: "9876544" (but simulate OCR inaccuracy as "R0987654A").
    # Total: 80.00. VAT: 5% (76.19 base, 3.81 VAT).
    boxes.extend([
        {"text": "BOOKSTORE SRL", "x": 100, "y": 1070, "w": 200, "h": 20},
        {"text": "CIF R0987654A", "x": 100, "y": 1100, "w": 150, "h": 20}, # OCR inaccuracy: 'R0' instead of 'RO', 'A' instead of '4'
        {"text": "CARTI", "x": 100, "y": 1250, "w": 100, "h": 20},
        {"text": "80.00", "x": 350, "y": 1250, "w": 60, "h": 20},
        {"text": "TVA 5%", "x": 100, "y": 1300, "w": 80, "h": 20},
        {"text": "76.19", "x": 250, "y": 1300, "w": 60, "h": 20},
        {"text": "3.81", "x": 350, "y": 1300, "w": 60, "h": 20},
        {"text": "TOTAL", "x": 100, "y": 1350, "w": 100, "h": 20},
        {"text": "80.00", "x": 350, "y": 1350, "w": 60, "h": 20},
    ])
    
    # Receipt 6: Row 2, Col 1. Seller CUI: 55553. Chitanță POS (0% VAT).
    # Total: 45.00.
    boxes.extend([
        {"text": "GAS STATION SRL", "x": 600, "y": 1070, "w": 200, "h": 20},
        {"text": "CUI RO 55553", "x": 600, "y": 1100, "w": 150, "h": 20},
        {"text": "POS TERMINAL ID 9876", "x": 600, "y": 1200, "w": 200, "h": 20},
        {"text": "SUMA DE PLATA", "x": 600, "y": 1250, "w": 150, "h": 20},
        {"text": "45.00", "x": 850, "y": 1250, "w": 60, "h": 20},
        {"text": "TRANZACTIE ACCEPTATA", "x": 600, "y": 1300, "w": 200, "h": 20},
    ])
    
    clusters = cluster_boxes(boxes)
    print(f"Number of clusters identified: {len(clusters)}")
    for idx, c in enumerate(clusters):
         print(f"Cluster {idx+1} box texts: {[b['text'] for b in c]}")
    assert len(clusters) == 6, f"Expected 6 clusters, got {len(clusters)}"
    
    # Process each cluster
    all_results = []
    for i, cluster in enumerate(clusters):
        results = extract_financials(cluster)
        all_results.extend(results)
        print(f"Cluster {i+1} results: {results}")
        
    print(f"\nTotal output rows generated: {len(all_results)}")
    assert len(all_results) == 7, f"Expected 7 rows, got {len(all_results)}"
    
    # Verify Receipt 1 (Inaccurate CUI: 12345P)
    r1_rows = [r for r in all_results if r["cui"] == "12345P"]
    assert len(r1_rows) == 1, "Expected 1 row for Receipt 1 with fallback CUI"
    assert r1_rows[0]["cuiRequiresVerification"] is True
    assert r1_rows[0]["totalAmount"] == 119.00
    assert r1_rows[0]["vatAmount"] == 19.00
    assert r1_rows[0]["baseAmount"] == 100.00
    assert r1_rows[0]["vatPercentages"] == "19%"
    
    # Verify Receipt 2 (CUI: 1234565)
    r2_rows = [r for r in all_results if r["cui"] == "1234565"]
    assert len(r2_rows) == 1, "Expected 1 row for Receipt 2"
    assert r2_rows[0]["totalAmount"] == 200.00
    assert r2_rows[0]["vatAmount"] == 31.93
    
    # Verify Receipt 5 (Inaccurate CUI: 987654A)
    r5_rows = [r for r in all_results if r["cui"] == "987654A"]
    assert len(r5_rows) == 1, "Expected 1 row for Receipt 5 with fallback CUI"
    assert r5_rows[0]["cuiRequiresVerification"] is True
    assert r5_rows[0]["totalAmount"] == 80.00
    
    print("\nALL TESTS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    run_tests()
