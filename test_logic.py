import re
import functools
import math

def is_valid_cui(cui):
    if not (2 <= len(cui) <= 10) or not cui.isdigit():
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
    for kw in buyer_keywords:
        if kw in text:
            return True
            
    for other in boxes:
        if other["x"] == box["x"] and other["y"] == box["y"]:
            continue
        other_text = other["text"].upper()
        has_buyer_kw = any(kw in other_text for kw in buyer_keywords)
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

def is_seller_cui_box(box, boxes, median_height):
    if is_phone_or_phone_label(box, boxes, median_height):
        return None
    cui = extract_cui(box["text"])
    if not cui:
        return None
    if is_buyer_cui_box(box, boxes, median_height):
        return None
    
    text = box["text"].upper()
    seller_keywords = ["CIF", "CUI", "CODFISCAL", "FISCAL", "C.I.F.", "C.F.", "RO"]
    has_seller_kw = any(kw in text for kw in seller_keywords)
    
    if not has_seller_kw:
        for other in boxes:
            if other["x"] == box["x"] and other["y"] == box["y"]:
                continue
            other_text = other["text"].upper()
            other_has_kw = any(kw in other_text for kw in seller_keywords)
            if not other_has_kw:
                continue
            dy = abs(box["y"] - other["y"])
            dx = abs(box["x"] - other["x"])
            if dy < median_height * 2.0 and dx < median_height * 12.0:
                has_seller_kw = True
                break
                
    if has_seller_kw:
        return cui
    return None

def recursive_xy_cut(boxes, median_height):
    if len(boxes) <= 1:
        return [boxes]
    
    # 1. Tăietură pe X
    sorted_x = sorted(boxes, key=lambda b: b["x"])
    x_intervals = []
    
    for b in sorted_x:
        if not x_intervals:
            x_intervals.append({"min": b["x"], "max": b["x"] + b["w"]})
        else:
            last = x_intervals[-1]
            if b["x"] <= last["max"] + median_height * 2.5:
                last["max"] = max(last["max"], b["x"] + b["w"])
            else:
                x_intervals.append({"min": b["x"], "max": b["x"] + b["w"]})
                
    if len(x_intervals) > 1:
        groups = [[] for _ in range(len(x_intervals))]
        for b in boxes:
            for i, interval in enumerate(x_intervals):
                if b["x"] >= interval["min"] - median_height and (b["x"] + b["w"]) <= interval["max"] + median_height:
                    groups[i].append(b)
                    break
        valid_groups = [g for g in groups if g]
        if len(valid_groups) > 1:
            res = []
            for g in valid_groups:
                res.extend(recursive_xy_cut(g, median_height))
            return res
            
    # 2. Tăietură pe Y
    sorted_y = sorted(boxes, key=lambda b: b["y"])
    y_intervals = []
    
    for b in sorted_y:
        if not y_intervals:
            y_intervals.append({"min": b["y"], "max": b["y"] + b["h"]})
        else:
            last = y_intervals[-1]
            if b["y"] <= last["max"] + median_height * 3.5:
                last["max"] = max(last["max"], b["y"] + b["h"])
            else:
                y_intervals.append({"min": b["y"], "max": b["y"] + b["h"]})
                
    if len(y_intervals) > 1:
        groups = [[] for _ in range(len(y_intervals))]
        for b in boxes:
            for i, interval in enumerate(y_intervals):
                if b["y"] >= interval["min"] - median_height and (b["y"] + b["h"]) <= interval["max"] + median_height:
                    groups[i].append(b)
                    break
        valid_groups = [g for g in groups if g]
        if len(valid_groups) > 1:
            res = []
            for g in valid_groups:
                res.extend(recursive_xy_cut(g, median_height))
            return res
            
    return [boxes]

def cluster_boxes(boxes):
    if len(boxes) <= 1:
        return [boxes]
    
    sorted_heights = sorted([b["h"] for b in boxes])
    median_height = sorted_heights[len(sorted_heights) // 2]
    
    unique_anchors = []
    unique_cuis = []
    for box in boxes:
        cui = is_seller_cui_box(box, boxes, median_height)
        if cui:
            is_dup = False
            for u in unique_anchors:
                dx = abs(u["x"] - box["x"])
                dy = abs(u["y"] - box["y"])
                if dx < median_height * 5.0 and dy < median_height * 2.0:
                    is_dup = True
                    break
            if not is_dup:
                unique_anchors.append(box)
                unique_cuis.append(cui)
                
    if len(unique_anchors) > 1:
        # Group into columns
        sorted_by_x = sorted(unique_anchors, key=lambda b: b["x"])
        columns = []
        for anchor in sorted_by_x:
            if columns and anchor["x"] - columns[-1][-1]["x"] < median_height * 12.0:
                columns[-1].append(anchor)
            else:
                columns.append([anchor])
                
        # Group into rows
        sorted_by_y = sorted(unique_anchors, key=lambda b: b["y"])
        rows = []
        for anchor in sorted_by_y:
            if rows and anchor["y"] - rows[-1][-1]["y"] < median_height * 15.0:
                rows[-1].append(anchor)
            else:
                rows.append([anchor])
                
        col_x = sorted([sum(b["x"] for b in col) / len(col) for col in columns])
        row_y = sorted([sum(b["y"] for b in row) / len(row) for row in rows])
        
        v_cuts = []
        if len(col_x) > 1:
            for i in range(len(col_x) - 1):
                v_cuts.append((col_x[i] + col_x[i+1]) / 2.0)
                
        h_cuts = []
        if len(row_y) > 1:
            for i in range(len(row_y) - 1):
                h_cuts.append((row_y[i] + row_y[i+1]) / 2.0)
                
        cell_to_anchor_idx = {}
        for idx, anchor in enumerate(unique_anchors):
            a_col = sum(1 for cut in v_cuts if anchor["x"] > cut)
            a_row = sum(1 for cut in h_cuts if anchor["y"] > cut)
            cell_to_anchor_idx[f"{a_row},{a_col}"] = idx
            
        groups = [[] for _ in range(len(unique_anchors))]
        for box in boxes:
            b_col = sum(1 for cut in v_cuts if box["x"] > cut)
            b_row = sum(1 for cut in h_cuts if box["y"] > cut)
            key = f"{b_row},{b_col}"
            if key in cell_to_anchor_idx:
                groups[cell_to_anchor_idx[key]].append(box)
            else:
                best_dist = float("inf")
                best_idx = 0
                for i, anchor in enumerate(unique_anchors):
                    dx = box["x"] - anchor["x"]
                    dy = box["y"] - anchor["y"]
                    dist = dx * dx + dy * dy
                    if dist < best_dist:
                        best_dist = dist
                        best_idx = i
                groups[best_idx].append(box)
        return groups
    else:
        clusters = recursive_xy_cut(boxes, median_height)
        clusters = [c for c in clusters if len(c) >= 3]
        if not clusters:
            return [boxes]
        
        def compare_clusters(c1, c2):
            if abs(c1[0]["y"] - c2[0]["y"]) < median_height * 5.0:
                return -1 if c1[0]["x"] < c2[0]["x"] else 1
            return -1 if c1[0]["y"] < c2[0]["y"] else 1
            
        return sorted(clusters, key=functools.cmp_to_key(compare_clusters))

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
    
    # Seller CUI
    seller_cui = None
    for box in boxes:
        cui = is_seller_cui_box(box, boxes, median_height)
        if cui:
            seller_cui = cui
            break
            
    # Total
    total_amount = None
    total_keywords = ["TOTAL", "SUMA", "ACHITAT"]
    lines = group_boxes_into_lines(boxes, median_height)
    
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
        # Fallback to largest number
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
            
            # Remove the percentage match from line_text to prevent value conflict
            clean_line_text = line_text.replace(pct_match.group(0), "")
            
            # Find decimal numbers
            dec_matches = re.findall(r"\b([0-9]+[.,][0-9]{2})\b", clean_line_text)
            vals = [float(v.replace(",", ".")) for v in dec_matches]
            
            vat_amount = None
            base_amount = None
            
            if len(vals) >= 2:
                # Math pair verification
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
                
                # Math pair verification for Base + Total
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
                            
                # Fallback: smaller is VAT, larger is Base
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
                    
        # Fallback legacy TOTAL TVA
        if not breakdowns:
            match = re.search(r"TOTAL\s*TVA[^0-9]{0,15}?([0-9]+[,.][0-9]{2})", full_text)
            if match:
                val = float(match.group(1).replace(",", "."))
                base = round(total_amount - val, 2) if total_amount else val
                breakdowns.append({"percentage": "Mixt", "vatAmount": val, "baseAmount": base})
                
    # Splitting logic
    results = []
    if breakdowns:
        for b in breakdowns:
            results.append({
                "cui": seller_cui,
                "totalAmount": round(b["baseAmount"] + b["vatAmount"], 2) if len(breakdowns) > 1 else (total_amount if total_amount is not None else round(b["baseAmount"] + b["vatAmount"], 2)),
                "vatAmount": b["vatAmount"],
                "baseAmount": b["baseAmount"],
                "vatPercentages": b["percentage"]
            })
    else:
        results.append({
            "cui": seller_cui,
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
    
    # Receipt 1: Row 0, Col 0. Seller CUI: 123453 (split). Buyer CUI: 87654329 (split, ignore).
    # Total: 119.00. VAT: 19% (100.00 base, 19.00 VAT).
    boxes.extend([
        {"text": "RETAIL STORE SRL", "x": 100, "y": 70, "w": 200, "h": 20},
        {"text": "CIF", "x": 100, "y": 100, "w": 40, "h": 20},
        {"text": "RO 123453", "x": 150, "y": 100, "w": 100, "h": 20},
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
    
    # Receipt 4: Row 1, Col 1. Seller CUI: 123456789. MULTIPLE VAT RATES (R3).
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
    
    # Receipt 5: Row 2, Col 0. Seller CUI: 9876544.
    # Total: 80.00. VAT: 5% (76.19 base, 3.81 VAT).
    boxes.extend([
        {"text": "BOOKSTORE SRL", "x": 100, "y": 1070, "w": 200, "h": 20},
        {"text": "CIF RO 9876544", "x": 100, "y": 1100, "w": 150, "h": 20},
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
    
    # Run clustering
    clusters = cluster_boxes(boxes)
    print(f"Number of clusters identified: {len(clusters)}")
    assert len(clusters) == 6, f"Expected 6 clusters, got {len(clusters)}"
    
    # Process each cluster
    all_results = []
    for i, cluster in enumerate(clusters):
        results = extract_financials(cluster)
        all_results.extend(results)
        print(f"Cluster {i+1} results: {results}")
        
    print(f"\nTotal output rows generated: {len(all_results)}")
    
    # There are 5 receipts with 1 VAT rate, and 1 receipt (Receipt 4) with 2 VAT rates.
    # Total output rows should be 5 * 1 + 2 = 7 rows!
    assert len(all_results) == 7, f"Expected 7 rows, got {len(all_results)}"
    
    # Verify Receipt 1 (CUI: 123453)
    r1_rows = [r for r in all_results if r["cui"] == "123453"]
    assert len(r1_rows) == 1, "Expected 1 row for Receipt 1"
    assert r1_rows[0]["totalAmount"] == 119.00
    assert r1_rows[0]["vatAmount"] == 19.00
    assert r1_rows[0]["baseAmount"] == 100.00
    assert r1_rows[0]["vatPercentages"] == "19%"
    
    # Verify Receipt 2 (CUI: 1234565)
    r2_rows = [r for r in all_results if r["cui"] == "1234565"]
    assert len(r2_rows) == 1, "Expected 1 row for Receipt 2"
    assert r2_rows[0]["totalAmount"] == 200.00
    assert r2_rows[0]["vatAmount"] == 31.93
    assert r2_rows[0]["baseAmount"] == 168.07
    assert r2_rows[0]["vatPercentages"] == "19%"
    
    # Verify Receipt 3 (CUI: 12345674)
    r3_rows = [r for r in all_results if r["cui"] == "12345674"]
    assert len(r3_rows) == 1, "Expected 1 row for Receipt 3"
    assert r3_rows[0]["totalAmount"] == 150.00
    assert r3_rows[0]["vatAmount"] == 12.39
    assert r3_rows[0]["baseAmount"] == 137.61
    assert r3_rows[0]["vatPercentages"] == "9%"
    
    # Verify Receipt 4 (CUI: 123456789) - Split (R3)
    r4_rows = sorted([r for r in all_results if r["cui"] == "123456789"], key=lambda x: float(x["vatPercentages"].replace("%", "")))
    assert len(r4_rows) == 2, "Expected 2 rows for Receipt 4"
    # Row 1 (9%): Total = 54.50, VAT = 4.50, Base = 50.00
    assert r4_rows[0]["vatPercentages"] == "9%"
    assert r4_rows[0]["totalAmount"] == 54.50
    assert r4_rows[0]["vatAmount"] == 4.50
    assert r4_rows[0]["baseAmount"] == 50.00
    # Row 2 (19%): Total = 119.00, VAT = 19.00, Base = 100.00
    assert r4_rows[1]["vatPercentages"] == "19%"
    assert r4_rows[1]["totalAmount"] == 119.00
    assert r4_rows[1]["vatAmount"] == 19.00
    assert r4_rows[1]["baseAmount"] == 100.00
    
    # Verify Receipt 5 (CUI: 9876544)
    r5_rows = [r for r in all_results if r["cui"] == "9876544"]
    assert len(r5_rows) == 1, "Expected 1 row for Receipt 5"
    assert r5_rows[0]["totalAmount"] == 80.00
    assert r5_rows[0]["vatAmount"] == 3.81
    assert r5_rows[0]["baseAmount"] == 76.19
    assert r5_rows[0]["vatPercentages"] == "5%"
    
    # Verify Receipt 6 (CUI: 55553) - POS
    r6_rows = [r for r in all_results if r["cui"] == "55553"]
    assert len(r6_rows) == 1, "Expected 1 row for Receipt 6"
    assert r6_rows[0]["totalAmount"] == 45.00
    assert r6_rows[0]["vatAmount"] == 0.0
    assert r6_rows[0]["baseAmount"] == 45.00
    assert r6_rows[0]["vatPercentages"] == "-"
    
    print("\nALL TESTS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    run_tests()
