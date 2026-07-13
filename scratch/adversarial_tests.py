import math
import re
import copy

# --- HELPER STRUCTURES ---

class OCRBoxItem:
    def __init__(self, text: str, x: float, y: float, w: float, h: float, rect=None):
        self.text = text
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rect = rect

    def __repr__(self):
        return f"OCRBoxItem(text={repr(self.text)}, x={self.x:.1f}, y={self.y:.1f}, w={self.w:.1f}, h={self.h:.1f})"

class VatBreakdown:
    def __init__(self, percentage: str, vatAmount: float, baseAmount: float):
        self.percentage = percentage
        self.vatAmount = vatAmount
        self.baseAmount = baseAmount

    def to_dict(self):
        return {"percentage": self.percentage, "vatAmount": self.vatAmount, "baseAmount": self.baseAmount}

class AccountingResult:
    def __init__(self):
        self.documentType = None
        self.documentTypeRequiresVerification = True
        self.documentSeries = None
        self.documentNumber = None
        self.documentDate = None
        self.cui = None
        self.cuiRequiresVerification = True
        self.companyName = None
        self.companyAddress = None
        self.companyIsVatPayer = None
        self.totalAmount = None
        self.totalRequiresVerification = True
        self.vatAmount = None
        self.vatRequiresVerification = True
        self.vatPercentages = None
        self.baseAmount = None
        self.vatBreakdowns = None
        self.fiscalWarnings = []
        self.suggestedAccount = None

    def __repr__(self):
        return (f"AccountingResult(type={self.documentType}, typeVerify={self.documentTypeRequiresVerification}, "
                f"series={self.documentSeries}, number={self.documentNumber}, date={self.documentDate}, "
                f"cui={self.cui}, cuiVerify={self.cuiRequiresVerification}, name={self.companyName}, "
                f"total={self.totalAmount}, totalVerify={self.totalRequiresVerification}, "
                f"vat={self.vatAmount}, vatVerify={self.vatRequiresVerification}, pct={self.vatPercentages}, "
                f"base={self.baseAmount}, warnings={self.fiscalWarnings}, account={self.suggestedAccount})")

# --- FUZZY & UTILITY FUNCTIONS ---

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

def contains_refined_ro(text):
    upper = text.upper()
    return bool(re.search(r"\bRO\d+|\bRO\b", upper))

def parse_formatted_amount(text):
    cleaned = text.strip().replace(" ", "")
    last_dot = cleaned.rfind(".")
    last_comma = cleaned.rfind(",")
    last_sep_idx = max(last_dot, last_comma)
    
    if last_sep_idx != -1:
        after_sep = cleaned[last_sep_idx+1:]
        digits_after = "".join([c for c in after_sep if c.isdigit()])
        chars_after_count = len(after_sep)
        
        if chars_after_count in [1, 2]:
            integer_part = "".join([c for c in cleaned[:last_sep_idx] if c.isdigit()])
            decimal_part = digits_after
            try:
                return float(f"{integer_part}.{decimal_part}")
            except ValueError:
                pass
        else:
            all_digits = "".join([c for c in cleaned if c.isdigit()])
            try:
                return float(all_digits)
            except ValueError:
                pass
    else:
        all_digits = "".join([c for c in cleaned if c.isdigit()])
        try:
            return float(all_digits)
        except ValueError:
            pass
    return None

def is_valid_cui(cui: str) -> bool:
    if not (4 <= len(cui) <= 10):
        return False
    if not cui.isdigit():
        return False
    # Ignore 10-digit numbers starting with "07", "02", or "03" (phone numbers)
    if len(cui) == 10 and (cui.startswith("07") or cui.startswith("02") or cui.startswith("03")):
        return False
        
    control_key = "753217532"[::-1]
    cui_reversed = cui[::-1]
    
    sum_val = 0
    control_digit = int(cui_reversed[0])
    
    for i in range(1, len(cui_reversed)):
        if i - 1 < len(control_key):
            sum_val += int(cui_reversed[i]) * int(control_key[i - 1])
            
    calc_control_digit = (sum_val * 10) % 11
    final_control_digit = 0 if calc_control_digit == 10 else calc_control_digit
    
    return final_control_digit == control_digit

def verify_with_anaf(cui: str, result: AccountingResult, simulate_timeout: bool = False):
    if simulate_timeout:
        result.cuiRequiresVerification = True
        return
    # Mocking some valid CUIs
    if cui == "8609468":
        result.companyName = "S.C. MEGA IMAGE S.R.L."
        result.companyAddress = "Bucuresti"
        result.companyIsVatPayer = True
        result.cuiRequiresVerification = False
    elif cui == "14399840":
        result.companyName = "S.C. DANTE INTERNATIONAL S.A."
        result.companyAddress = "Bucuresti"
        result.companyIsVatPayer = True
        result.cuiRequiresVerification = False
    else:
        result.companyName = "Mocked Company"
        result.companyAddress = "Mocked Address"
        result.companyIsVatPayer = True
        result.cuiRequiresVerification = False

# --- AGENTS IMPLEMENTATION ---

class DocumentClassificationAgent:
    def process(self, text_blocks, boxes, result):
        full_text = " ".join(text_blocks).upper()
        has_pos = ("TERMINAL ID" in full_text or 
                   "PIN VERIFICAT" in full_text or 
                   "TRANZACTIE ACCEPTATA" in full_text or 
                   "TRANZACTIE APROBATA" in full_text or 
                   "POS" in full_text)
        
        if "FACTURA" in full_text or "INVOICE" in full_text:
            result.documentType = "Factură"
            result.documentTypeRequiresVerification = False
        elif "BON FISCAL" in full_text or "CASA DE MARCAT" in full_text or "BF." in full_text or "BF " in full_text:
            result.documentType = "Bon Fiscal"
            result.documentTypeRequiresVerification = False
        elif has_pos:
            result.documentType = "Chitanță POS"
            result.documentTypeRequiresVerification = False
        elif "CHITANTA" in full_text:
            result.documentType = "Chitanță de mână"
            result.documentTypeRequiresVerification = False
        elif "BENZINA" in full_text or "MOTORINA" in full_text or "DIESEL" in full_text:
            result.documentType = "Fișă Combustibil"
            result.documentTypeRequiresVerification = False
        else:
            result.documentType = "Necunoscut"
            result.documentTypeRequiresVerification = True

class DocumentDetailsAgent:
    def process(self, text_blocks, boxes, result):
        full_text = " \n ".join(b.text for b in boxes).upper()
        
        series_pattern = r"(?:SERIA|SERIE|SERIA:|CHITANTA\s*SERIA)\s*([A-Z]{1,5})"
        match = re.search(series_pattern, full_text)
        if match:
            result.documentSeries = match.group(1).strip()
            
        number_pattern = r"(?:NR\.?|NUMAR|BON\s*NR\.?|FACTURA\s*NR\.?|CHITANTA\s*NR\.?|BF\.?|ID\s*TRX\.?)\s*[:]*\s*([0-9]{1,15})"
        match = re.search(number_pattern, full_text)
        if match:
            result.documentNumber = match.group(1).strip()
            
        date_pattern = r"(?:DATA\s*[:]*\s*)?([0-3]?[0-9][\.\-\/][0-1]?[0-9][\.\-\/](?:20)?[0-9]{2})"
        match = re.search(date_pattern, full_text)
        if match:
            result.documentDate = match.group(1).strip()

def is_buyer_cui_box(box, boxes, median_height):
    text = box.text.upper()
    buyer_keywords = ["CLIENT", "CUMP", "BENEF", "CNP", "C.N.P"]
    
    for kw in buyer_keywords:
        if kw in text:
            return True
            
    tokens = re.findall(r"\w+", text)
    for token in tokens:
        for kw in buyer_keywords:
            tolerance = 0 if len(kw) <= 3 else 1
            if is_fuzzy_match(token, kw, tolerance):
                return True

    for other in boxes:
        if other.x == box.x and other.y == box.y:
            continue
        other_text = other.text.upper()
        has_buyer_kw = any(kw in other_text for kw in buyer_keywords)
        if not has_buyer_kw:
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
        
        dy = box.y - other.y
        dx = box.x - other.x
        
        if abs(dy) < median_height * 1.5 and dx > 0 and dx < median_height * 12.0:
            return True
        if dy > 0 and dy < median_height * 2.5 and abs(dx) < median_height * 6.0:
            return True
    return False

def clean_fallback_candidate(raw_text):
    s = "".join([c for c in raw_text.upper() if c.isalnum()])
    prefixes = ["CIF", "CUI", "RO", "R0", "COD", "FISCAL", "CODFISCAL"]
    changed = True
    while changed:
        changed = False
        for prefix in prefixes:
            if s.startswith(prefix):
                s = s[len(prefix):]
                changed = True
    if 2 <= len(s) <= 12 and any(c.isdigit() for c in s):
        return s
    return None

def is_phone_or_phone_label(box, boxes, median_height):
    text = box.text.upper()
    phone_labels = ["TEL", "FAX", "MOBIL", "TELEFON"]
    for label in phone_labels:
        if label in text:
            return True
            
    digits = "".join([c for c in text if c.isdigit()])
    if len(digits) == 10 and (digits.startswith("07") or digits.startswith("02") or digits.startswith("03")):
        return True
        
    for other in boxes:
        if other.x == box.x and other.y == box.y:
            continue
        other_text = other.text.upper()
        has_phone_label = any(label in other_text for label in phone_labels)
        if not has_phone_label:
            continue
        dy = abs(box.y - other.y)
        dx = abs(box.x - other.x)
        if dy < median_height * 1.5 and dx < median_height * 12.0:
            return True
    return False

def extract_cui(text):
    clean = text.upper().replace(" ", "").replace(".", "").replace(":", "").replace("-", "")
    matches = re.findall(r"\d{2,10}", clean)
    for candidate in matches:
        if is_valid_cui(candidate):
            return candidate
    return None

class CuiExtractorAgent:
    def __init__(self, simulate_timeout=False):
        self.simulate_timeout = simulate_timeout

    def process(self, text_blocks, boxes, result):
        sorted_heights = sorted([b.h for b in boxes])
        median_height = sorted_heights[len(sorted_heights) // 2] if sorted_heights else 15.0

        cui_keywords = ["CIF", "CUI", "CODFISCAL", "R0", "IDENTIFICARE"]
        candidate_boxes = []
        
        for box in boxes:
            if is_buyer_cui_box(box, boxes, median_height): continue
            if is_phone_or_phone_label(box, boxes, median_height): continue
            clean_text = box.text.upper().replace(".", "").replace(" ", "")
            
            is_cand = any(kw in clean_text or (len(clean_text) <= len(kw) + 2 and is_fuzzy_match(clean_text, kw, 1)) for kw in cui_keywords)
            if not is_cand:
                is_cand = contains_refined_ro(box.text)
            if is_cand:
                candidate_boxes.append(box)

        # 1. Check candidate box text
        for box in candidate_boxes:
            if "%" in box.text: continue
            if is_buyer_cui_box(box, boxes, median_height): continue
            if is_phone_or_phone_label(box, boxes, median_height): continue
            if let_cui := extract_cui(box.text):
                result.cui = let_cui
                result.cuiRequiresVerification = False
                verify_with_anaf(let_cui, result, self.simulate_timeout)
                return

        # 2. Check nearby boxes
        for keyword_box in candidate_boxes:
            nearby_boxes = sorted(
                [b for b in boxes if not (b.x == keyword_box.x and b.y == keyword_box.y)],
                key=lambda b: (b.x - keyword_box.x)**2 + (b.y - keyword_box.y)**2
            )
            for nb in nearby_boxes:
                dist = math.sqrt((nb.x - keyword_box.x)**2 + (nb.y - keyword_box.y)**2)
                if dist >= median_height * 3.0: continue
                if nb.text.contains("%") if hasattr(nb.text, "contains") else "%" in nb.text: continue
                if is_buyer_cui_box(nb, boxes, median_height): continue
                if is_phone_or_phone_label(nb, boxes, median_height): continue
                if let_cui := extract_cui(nb.text):
                    result.cui = let_cui
                    result.cuiRequiresVerification = False
                    verify_with_anaf(let_cui, result, self.simulate_timeout)
                    return

        # 3. Check any box
        for box in boxes:
            if "%" in box.text: continue
            if is_buyer_cui_box(box, boxes, median_height): continue
            if is_phone_or_phone_label(box, boxes, median_height): continue
            if let_cui := extract_cui(box.text):
                result.cui = let_cui
                result.cuiRequiresVerification = False
                verify_with_anaf(let_cui, result, self.simulate_timeout)
                return

        # 4. Fallback for typos
        fallback_candidates = []
        for box in candidate_boxes:
            if is_buyer_cui_box(box, boxes, median_height): continue
            if is_phone_or_phone_label(box, boxes, median_height): continue
            if cleaned := clean_fallback_candidate(box.text):
                fallback_candidates.append((cleaned, 0.0))

        for keyword_box in candidate_boxes:
            nearby = [b for b in boxes if not (b.x == keyword_box.x and b.y == keyword_box.y)]
            for nb in nearby:
                dist = math.sqrt((nb.x - keyword_box.x)**2 + (nb.y - keyword_box.y)**2)
                if dist >= median_height * 5.0: continue
                if "%" in nb.text: continue
                if is_buyer_cui_box(nb, boxes, median_height): continue
                if is_phone_or_phone_label(nb, boxes, median_height): continue
                if cleaned := clean_fallback_candidate(nb.text):
                    fallback_candidates.append((cleaned, dist))

        if fallback_candidates:
            fallback_candidates.sort(key=lambda x: x[1])
            best = fallback_candidates[0][0]
            result.cui = best
            result.cuiRequiresVerification = True
            verify_with_anaf(best, result, self.simulate_timeout)
            return

        result.cuiRequiresVerification = True

class FinancialAmountsAgent:
    def process(self, text_blocks, boxes, result):
        full_text = "\n".join(text_blocks).upper()
        sorted_heights = sorted([b.h for b in boxes])
        median_height = sorted_heights[len(sorted_heights) // 2] if sorted_heights else 15.0

        total_keywords = ["TOTAL", "SUMA", "ACHITAT"]
        total_amount = None
        total_found = False

        # Group boxes into lines
        lines = []
        sorted_by_y = sorted(boxes, key=lambda b: b.y)
        if sorted_by_y:
            current_line = [sorted_by_y[0]]
            y_tolerance = median_height * 0.4
            for box in sorted_by_y[1:]:
                avg_y = sum(b.y for b in current_line) / len(current_line)
                if abs(box.y - avg_y) < y_tolerance:
                    current_line.append(box)
                else:
                    lines.append(current_line)
                    current_line = [box]
            lines.append(current_line)

        for line in lines:
            line.sort(key=lambda b: b.x)

        # Spatial search
        for line in lines:
            for idx, box in enumerate(line):
                clean_text = box.text.upper().replace(" ", "").replace(":", "")
                if "SUBTOTAL" in clean_text: continue
                if any(kw in clean_text or (len(clean_text) <= len(kw) + 2 and is_fuzzy_match(clean_text, kw, 1)) for kw in total_keywords):
                    nearby = [b for b in boxes if not (b.x == box.x and b.y == box.y)]
                    check_text = box.text.upper()
                    for nb in nearby:
                        dist = math.sqrt((nb.x - box.x)**2 + (nb.y - box.y)**2)
                        if dist < median_height * 2.0:
                            check_text += " " + nb.text.upper()
                    
                    check_text = check_text.replace("TVA INCLUS", "").replace("TVA INCL", "").replace("TAXE INCLUSE", "").replace("TAXA INCLUSA", "")
                    if any(tax in check_text for tax in ["TVA", "TAXA", "TAXE"]):
                        continue

                    # Search to the right
                    for l_box in line:
                        if l_box.x <= box.x: continue
                        val = parse_formatted_amount(l_box.text)
                        if val is not None:
                            total_amount = val
                            total_found = True
                            break
                if total_found: break
            if total_found: break

        # Regex fallback
        if not total_found:
            total_pattern = r"(?:TOTAL|SUMA|ACHITAT|REST)\s*(?:LEI)?\s*[:=]*\s*([0-9\s]+[.,][0-9]{2})"
            match = re.search(total_pattern, full_text)
            if match:
                total_amount = parse_formatted_amount(match.group(1))
                total_found = True

        if not total_found:
            cui_float = None
            if result.cui:
                clean_cui = "".join(c for c in result.cui if c.isdigit())
                if clean_cui:
                    try:
                        cui_float = float(clean_cui)
                    except ValueError:
                        pass
            matches = re.findall(r"\b([0-9\s]+[.,][0-9]{2})\b", full_text)
            amounts = []
            for m in matches:
                val = parse_formatted_amount(m)
                if val is not None and val not in [24.0, 21.0, 19.0, 11.0, 9.0, 5.0] and val != cui_float:
                    amounts.append(val)
            if amounts:
                total_amount = max(amounts)

        result.totalAmount = total_amount

        # VAT Breakdowns
        breakdowns = []
        is_receipt = any(kw in full_text for kw in ["TERMINAL ID", "PIN VERIFICAT", "POS", "CHITANTA POS"])
        
        if is_receipt:
            breakdowns.append(VatBreakdown(percentage="-", vatAmount=0.0, baseAmount=total_amount or 0.0))
        else:
            for line in lines:
                line_text = " ".join(b.text for b in line)
                pct_match = re.search(r"\b([0-9]{1,2})(?:[.,][0-9]{1,2})?\s*%", line_text)
                if not pct_match: continue
                rate = float(pct_match.group(1))
                clean_line_text = line_text.replace(pct_match.group(0), "")
                
                dec_matches = re.findall(r"\b([0-9\s]+[.,][0-9]{2})\b", clean_line_text)
                vals = []
                for v in dec_matches:
                    parsed = parse_formatted_amount(v)
                    if parsed is not None:
                        vals.append(parsed)

                vat_amount = None
                base_amount = None

                if len(vals) >= 2:
                    for i in range(len(vals)):
                        for j in range(len(vals)):
                            if i == j: continue
                            base_cand = vals[i]
                            vat_cand = vals[j]
                            if abs(vat_cand - base_cand * (rate / 100.0)) < 0.05:
                                vat_amount = vat_cand
                                base_amount = base_cand
                                break
                        if vat_amount is not None: break

                    if vat_amount is None:
                        for i in range(len(vals)):
                            for j in range(len(vals)):
                                if i == j: continue
                                base_cand = vals[i]
                                total_cand = vals[j]
                                if abs(total_cand - base_cand * (1.0 + rate / 100.0)) < 0.05:
                                    base_amount = base_cand
                                    vat_amount = round(total_cand - base_cand, 2)
                                    break
                            if vat_amount is not None: break

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
                    if not any(b.percentage == pct_str for b in breakdowns):
                        breakdowns.append(VatBreakdown(percentage=pct_str, vatAmount=vat_amount, baseAmount=base_amount))

            if not breakdowns:
                match = re.search(r"TOTAL\s*TVA[^0-9]{0,15}?([0-9]+[,.][0-9]{2})", full_text)
                if match:
                    val = parse_formatted_amount(match.group(1))
                    base = round(total_amount - val, 2) if total_amount else val
                    breakdowns.append(VatBreakdown(percentage="Mixt", vatAmount=val, baseAmount=base))

        if total_amount is None and breakdowns:
            sum_base = sum(b.baseAmount for b in breakdowns)
            sum_vat = sum(b.vatAmount for b in breakdowns)
            result.totalAmount = round(sum_base + sum_vat, 2)

        if breakdowns:
            result.vatBreakdowns = breakdowns
            result.baseAmount = sum(b.baseAmount for b in breakdowns)
            result.vatAmount = sum(b.vatAmount for b in breakdowns)
            result.vatPercentages = ", ".join(b.percentage for b in breakdowns)
        else:
            result.baseAmount = result.totalAmount
            result.vatAmount = 0.0
            result.vatPercentages = "-"

class FiscalComplianceAgent:
    def __init__(self, buyer_cui=None, bnr_eur_rate=5.0):
        self.buyer_cui = buyer_cui
        self.bnr_eur_rate = bnr_eur_rate

    def process(self, text_blocks, boxes, result):
        full_text = " ".join(text_blocks).upper()
        if result.documentType == "Bon Fiscal":
            if self.buyer_cui:
                normalized_full_text = full_text.replace(" ", "")
                normalized_buyer = self.buyer_cui.upper().replace(" ", "")
                if normalized_buyer not in normalized_full_text:
                    result.fiscalWarnings.append(f"Atenție: Bonul fiscal nu conține CUI-ul cumpărătorului ({self.buyer_cui}). TVA-ul este complet nedeductibil!")
                    result.documentTypeRequiresVerification = True
            else:
                result.fiscalWarnings.append("Sfat: Introduceți CUI-ul clientului pentru a verifica deductibilitatea bonului.")

            if result.totalAmount:
                limit_ron = self.bnr_eur_rate * 100.0
                if result.totalAmount > limit_ron:
                    result.fiscalWarnings.append(f"Atenție: Bonul fiscal depășește limita de ~100 EUR ({limit_ron:.2f} RON) pentru a fi considerat factură simplificată.")
                    result.totalRequiresVerification = True

        if result.documentType == "Factură":
            has_seria = "SERIA" in full_text or "SERIE" in full_text
            has_numar = "NR." in full_text or "NUMAR" in full_text or "NO." in full_text
            if not has_seria and not has_numar:
                result.fiscalWarnings.append("Atenție: Documentul a fost clasificat ca Factură, dar nu conține elemente obligatorii clare (Seria / Numărul).")
                result.documentTypeRequiresVerification = True

class AccountingValidationAgent:
    """
    Port of Swift's AccountingValidationAgent containing Romania 2026 tax logic.
    Also contains the 2-digit year bug from the Swift implementation to verify it.
    """
    def get_year_from_date(self, date_str):
        if not date_str: return None
        components = re.split(r'[.\-\/]', date_str)
        if components:
            last = components[-1].strip()
            if last.isdigit():
                year = int(last)
                if len(last) == 2:
                    # Swift bug: Hardcoded year <= 24.
                    # In 2026, receipts from 2025 (25) or 2026 (26) will evaluate as year > 24,
                    # returning 1900 + year (1925 / 1926).
                    # Since 1925 / 1926 <= 2024, they will NOT receive VAT corrections!
                    if year <= 24:
                        return 2000 + year
                    else:
                        return 1900 + year
                elif len(last) == 4:
                    return year
        return None

    def process(self, text_blocks, boxes, result):
        full_text = " ".join(text_blocks).upper()
        self.correct_vat_rates(result, full_text)
        self.validate_mathematically(result)
        self.suggest_account(result, full_text)
        self.add_specific_warnings(result, full_text)

    def correct_vat_rates(self, result, full_text):
        if result.documentDate:
            year = self.get_year_from_date(result.documentDate)
            if year is not None and year <= 2024:
                return # Keep old rates for pre-2025 receipts

        if not result.vatPercentages: return

        if result.vatBreakdowns:
            updated_breakdowns = []
            updated_percentages = []
            corrected_any = False

            for b in result.vatBreakdowns:
                new_pct = b.percentage
                new_base = b.baseAmount
                new_vat = b.vatAmount

                if b.percentage == "19%":
                    new_pct = "21%"
                    total = b.baseAmount + b.vatAmount
                    new_base = round(total / 1.21, 2)
                    new_vat = round(total - new_base, 2)
                    corrected_any = True
                    result.fiscalWarnings.append("Corecție automată: Cota TVA 19% (veche) a fost recalculată la 21% (cota 2026). Verificați dacă bonul e din 2025+.")
                elif b.percentage == "5%":
                    new_pct = "11%"
                    total = b.baseAmount + b.vatAmount
                    new_base = round(total / 1.11, 2)
                    new_vat = round(total - new_base, 2)
                    corrected_any = True
                    result.fiscalWarnings.append("Corecție automată: Cota TVA 5% (veche) a fost recalculată la 11% (cota 2026).")
                elif b.percentage == "9%":
                    is_housing = any(h in full_text for h in ["LOCUINT", "APARTAMENT", "IMOBIL"])
                    if not is_housing:
                        new_pct = "11%"
                        total = b.baseAmount + b.vatAmount
                        new_base = round(total / 1.11, 2)
                        new_vat = round(total - new_base, 2)
                        corrected_any = True
                        result.fiscalWarnings.append("Corecție automată: Cota TVA 9% este valabilă doar pentru locuințe noi (până la 31.07.2026). Recalculat la 11%.")

                updated_breakdowns.append(VatBreakdown(percentage=new_pct, vatAmount=new_vat, baseAmount=new_base))
                updated_percentages.append(new_pct)

            if corrected_any:
                result.vatBreakdowns = updated_breakdowns
                result.baseAmount = sum(b.baseAmount for b in updated_breakdowns)
                result.vatAmount = sum(b.vatAmount for b in updated_breakdowns)
                unique_pcts = []
                for p in updated_percentages:
                    if p not in unique_pcts: unique_pcts.append(p)
                result.vatPercentages = ", ".join(unique_pcts)
        else:
            # Single rate fallback
            vat_pct = result.vatPercentages
            if "19%" in vat_pct:
                old_vat = result.vatAmount or 0.0
                if result.totalAmount and old_vat > 0:
                    new_base = round(result.totalAmount / 1.21, 2)
                    new_vat = round(result.totalAmount - new_base, 2)
                    result.baseAmount = new_base
                    result.vatAmount = new_vat
                    result.vatPercentages = "21%"
                    result.fiscalWarnings.append("Corecție automată: Cota TVA 19% (veche) a fost recalculată la 21% (cota 2026). Verificați dacă bonul e din 2025+.")
            elif "5%" in vat_pct and "15%" not in vat_pct and "25%" not in vat_pct:
                if result.totalAmount:
                    new_base = round(result.totalAmount / 1.11, 2)
                    new_vat = round(result.totalAmount - new_base, 2)
                    result.baseAmount = new_base
                    result.vatAmount = new_vat
                    result.vatPercentages = "11%"
                    result.fiscalWarnings.append("Corecție automată: Cota TVA 5% (veche) a fost recalculată la 11% (cota 2026).")
            elif vat_pct == "9%":
                is_housing = any(h in full_text for h in ["LOCUINT", "APARTAMENT", "IMOBIL"])
                if not is_housing:
                    if result.totalAmount:
                        new_base = round(result.totalAmount / 1.11, 2)
                        new_vat = round(result.totalAmount - new_base, 2)
                        result.baseAmount = new_base
                        result.vatAmount = new_vat
                        result.vatPercentages = "11%"
                        result.fiscalWarnings.append("Corecție automată: Cota TVA 9% este valabilă doar pentru locuințe noi (până la 31.07.2026). Recalculat la 11%.")

    def validate_mathematically(self, result):
        if result.totalAmount is None or result.vatAmount is None or result.baseAmount is None:
            return
        expected = round(result.baseAmount + result.vatAmount, 2)
        diff = abs(result.totalAmount - expected)
        if 0.02 < diff < result.totalAmount * 0.5:
            corrected_base = round(result.totalAmount - result.vatAmount, 2)
            if corrected_base > 0:
                result.baseAmount = corrected_base
                result.fiscalWarnings.append(f"Corecție automată: Baza recalculată ({corrected_base:.2f}) din Total ({result.totalAmount:.2f}) - TVA ({result.vatAmount:.2f}). Diferență detectată: {diff:.2f} RON.")
        elif diff >= result.totalAmount * 0.5:
            result.fiscalWarnings.append(f"⚠️ Eroare gravă: Total ({result.totalAmount:.2f}) ≠ Bază ({result.baseAmount:.2f}) + TVA ({result.vatAmount:.2f}). Diferență: {diff:.2f} RON. Verificare manuală necesară!")
            result.totalRequiresVerification = True

    def suggest_account(self, result, full_text):
        if result.documentType == "Chitanță de mână":
            result.suggestedAccount = "5311"
            return
        if result.documentType == "Chitanță POS":
            result.suggestedAccount = "5125"
            return
        if any(kw in full_text for kw in ["BENZINA", "MOTORINA", "DIESEL", "GPL", "CARBURANT", "MOL ", "PETROM", "OMV", "ROMPETROL", "LUKOIL", "SOCAR"]):
            result.suggestedAccount = "6022"
        elif any(kw in full_text for kw in ["GAZ ", "GAZE", "MAGISTRAL", "ELECTRICA", "ENEL", "E.ON", "APA ", "HIDRO"]):
            result.suggestedAccount = "605"
        elif any(kw in full_text for kw in ["VODAFONE", "ORANGE", "TELEKOM", "DIGI", "RCS", "RDS"]):
            result.suggestedAccount = "626"
        elif any(kw in full_text for kw in ["RESTAURANT", "PIZZ", "FAST FOOD", "CAFEA", "COFFEE", "MENIU"]):
            result.suggestedAccount = "625"
        elif any(kw in full_text for kw in ["HOTEL", "CAZARE", "PENSIUNE", "BOOKING", "ACCOMMODATION"]):
            result.suggestedAccount = "625"
        elif any(kw in full_text for kw in ["TAXI", "UBER", "BOLT", "CFR", "BILET", "TRANSPORT", "METROREX", "STB"]):
            result.suggestedAccount = "624"
        elif any(kw in full_text for kw in ["PAPER", "HARTIE", "TONER", "CARTUS", "PAPETARIE", "BIROU"]):
            result.suggestedAccount = "6028"
        elif any(kw in full_text for kw in ["KAUFLAND", "LIDL", "MEGA IMAGE", "CARREFOUR", "AUCHAN", "PROFI", "PENNY", "CORA"]):
            result.suggestedAccount = "604"
        elif any(kw in full_text for kw in ["DOUGLAS", "SEPHORA", "COSMET", "PARFUM"]):
            result.suggestedAccount = "604"
        elif any(kw in full_text for kw in ["FARMACI", "CATENA", "SENSIBLU", "HELPNET", "DONA", "MEDICAMENTE"]):
            result.suggestedAccount = "604"

    def add_specific_warnings(self, result, full_text):
        is_restaurant = any(kw in full_text for kw in ["RESTAURANT", "PIZZ", "FAST FOOD", "CAFEA", "MENIU"])
        has_alcohol = any(kw in full_text for kw in ["BERE", "VIN ", "WHISKY", "VODKA", "COCKTAIL", "ALCOOL"])
        if is_restaurant and has_alcohol:
            result.fiscalWarnings.append("Atenție: Factura de restaurant conține și băuturi alcoolice. TVA-ul poate fi mixt: 11% pentru mâncare, 21% pentru alcool.")
        
        if result.documentDate:
            year = self.get_year_from_date(result.documentDate)
            if year is not None and year <= 2024:
                result.fiscalWarnings = [w for w in result.fiscalWarnings if "Corecție automată: Cota TVA" not in w]


# --- COORDINATE TRANSFORMATION FOR Skew/Rotation ---

def rotate_point(x, y, cx, cy, angle_rad):
    cos_a = math.cos(angle_rad)
    sin_a = math.sin(angle_rad)
    dx = x - cx
    dy = y - cy
    rx = cx + dx * cos_a - dy * sin_a
    ry = cy + dx * sin_a + dy * cos_a
    return rx, ry

def get_rotated_rect_container(x, y, w, h, angle_rad, cx, cy):
    # Unrotated corners
    tl = (x, y)
    tr = (x + w, y)
    bl = (x, y + h)
    br = (x + w, y + h)
    
    # Rotate corners around center of canvas
    tl_r = rotate_point(tl[0], tl[1], cx, cy, angle_rad)
    tr_r = rotate_point(tr[0], tr[1], cx, cy, angle_rad)
    bl_r = rotate_point(bl[0], bl[1], cx, cy, angle_rad)
    br_r = rotate_point(br[0], br[1], cx, cy, angle_rad)
    
    class RectContainer:
        def __init__(self, tl, tr, bl, br):
            self.topLeft_x = tl[0]
            self.topLeft_y = tl[1]
            self.topRight_x = tr[0]
            self.topRight_y = tr[1]
            self.bottomLeft_x = bl[0]
            self.bottomLeft_y = bl[1]
            self.bottomRight_x = br[0]
            self.bottomRight_y = br[1]
            
        def get(self, prop, default):
            return getattr(self, prop, default)
            
    return RectContainer(tl_r, tr_r, bl_r, br_r)


# --- ORCHESTRATOR SIMULATOR ---

class AccountingOrchestrator:
    def __init__(self, simulate_timeout=False, bnr_eur_rate=5.0):
        self.simulate_timeout = simulate_timeout
        self.bnr_eur_rate = bnr_eur_rate

    def process_ocr_result(self, boxes, buyer_cui=None) -> list:
        # Run clustering
        clusters = self.cluster_boxes(boxes)
        results = []
        for cluster in clusters:
            res = self.process_single_cluster(cluster, buyer_cui)
            results.extend(res)
        return results

    def process_single_cluster(self, boxes, buyer_cui=None) -> list:
        # Generate text blocks (lines)
        text_blocks = []
        sorted_by_y = sorted(boxes, key=lambda b: b.y)
        if sorted_by_y:
            lines = []
            current_line = [sorted_by_y[0]]
            sorted_heights = sorted([b.h for b in sorted_by_y])
            median_height = sorted_heights[len(sorted_heights) // 2]
            y_tolerance = median_height * 0.4
            
            for box in sorted_by_y[1:]:
                avg_y = sum(b.y for b in current_line) / len(current_line)
                if abs(box.y - avg_y) < y_tolerance:
                    current_line.append(box)
                else:
                    lines.append(current_line)
                    current_line = [box]
            lines.append(current_line)
            
            for line in lines:
                sorted_line = sorted(line, key=lambda b: b.x)
                text_blocks.append(" ".join(b.text for b in sorted_line))
                
        result = AccountingResult()
        
        agents = [
            DocumentClassificationAgent(),
            DocumentDetailsAgent(),
            CuiExtractorAgent(simulate_timeout=self.simulate_timeout),
            FinancialAmountsAgent(),
            FiscalComplianceAgent(buyer_cui=buyer_cui, bnr_eur_rate=self.bnr_eur_rate),
            AccountingValidationAgent()
        ]
        
        for agent in agents:
            # We simulate async processing
            agent.process(text_blocks, boxes, result)
            
        # Split logic
        if result.vatBreakdowns and len(result.vatBreakdowns) > 0:
            split_results = []
            for b in result.vatBreakdowns:
                split_copy = copy.deepcopy(result)
                split_copy.vatPercentages = b.percentage
                split_copy.vatAmount = b.vatAmount
                split_copy.baseAmount = b.baseAmount
                split_copy.totalAmount = round(b.baseAmount + b.vatAmount, 2) if len(result.vatBreakdowns) > 1 else (result.totalAmount if result.totalAmount is not None else round(b.baseAmount + b.vatAmount, 2))
                split_copy.vatBreakdowns = None
                split_results.append(split_copy)
            return split_results
            
        return [result]

    def cluster_boxes(self, boxes):
        if len(boxes) <= 1:
            return [boxes]
            
        # Deskewing
        angles = []
        for box in boxes:
            if box.rect is not None:
                tr_y, tl_y = box.rect.topRight_y, box.rect.topLeft_y
                tr_x, tl_x = box.rect.topRight_x, box.rect.topLeft_x
                theta_i = math.atan2(tr_y - tl_y, tr_x - tl_x)
                angles.append(theta_i)
            else:
                angles.append(0.0)
        angles.sort()
        theta = angles[len(angles) // 2] if angles else 0.0
        
        cos_t = math.cos(-theta)
        sin_t = math.sin(-theta)
        
        deskewed_boxes = []
        for box in boxes:
            cx = box.x + box.w / 2.0
            cy = box.y + box.h / 2.0
            cx_prime = cx * cos_t - cy * sin_t
            cy_prime = cx * sin_t + cy * cos_t
            new_x = cx_prime - box.w / 2.0
            new_y = cy_prime - box.h / 2.0
            
            new_rect = None
            if box.rect is not None:
                new_rect = {
                    "topLeft_x": box.rect.topLeft_x * cos_t - box.rect.topLeft_y * sin_t,
                    "topLeft_y": box.rect.topLeft_x * sin_t + box.rect.topLeft_y * cos_t,
                    "topRight_x": box.rect.topRight_x * cos_t - box.rect.topRight_y * sin_t,
                    "topRight_y": box.rect.topRight_x * sin_t + box.rect.topRight_y * cos_t,
                    "bottomLeft_x": box.rect.bottomLeft_x * cos_t - box.rect.bottomLeft_y * sin_t,
                    "bottomLeft_y": box.rect.bottomLeft_x * sin_t + box.rect.bottomLeft_y * cos_t,
                    "bottomRight_x": box.rect.bottomRight_x * cos_t - box.rect.bottomRight_y * sin_t,
                    "bottomRight_y": box.rect.bottomRight_x * sin_t + box.rect.bottomRight_y * cos_t
                }
                class RectContainer:
                    def __init__(self, d):
                        self.topLeft_x = d["topLeft_x"]
                        self.topLeft_y = d["topLeft_y"]
                        self.topRight_x = d["topRight_x"]
                        self.topRight_y = d["topRight_y"]
                        self.bottomLeft_x = d["bottomLeft_x"]
                        self.bottomLeft_y = d["bottomLeft_y"]
                        self.bottomRight_x = d["bottomRight_x"]
                        self.bottomRight_y = d["bottomRight_y"]
                    def get(self, prop, default):
                        return getattr(self, prop, default)
                new_rect = RectContainer(new_rect)
            
            deskewed_boxes.append(OCRBoxItem(box.text, new_x, new_y, box.w, box.h, new_rect))

        sorted_heights = sorted([b.h for b in deskewed_boxes])
        median_height = sorted_heights[len(sorted_heights) // 2]
        
        # Anchors
        def is_buyer_text(txt):
            return any(kw in txt.upper() for kw in ["CLIENT", "CUMP", "BENEF", "CNP"])
            
        def is_cui_anchor(b):
            if is_buyer_text(b.text): return False
            if "%" in b.text: return False
            
            seller_keywords = ["CIF", "CUI", "CODFISCAL", "FISCAL", "COD FISCAL"]
            clean_text = b.text.upper().replace(".", "").replace(" ", "")
            for kw in seller_keywords:
                if kw.replace(" ", "") in clean_text: return True
                
            cui = extract_cui(b.text)
            if cui:
                if not is_buyer_cui_box(b, deskewed_boxes, median_height):
                    return True
            return False
            
        raw_anchors = [b for b in deskewed_boxes if is_cui_anchor(b)]
        cui_anchors = []
        for a in raw_anchors:
            is_dup = False
            for u in cui_anchors:
                dx = abs(u.x - a.x)
                dy = abs(u.y - a.y)
                if dx < median_height * 5.0 and dy < median_height * 3.0:
                    is_dup = True
                    break
            if not is_dup:
                cui_anchors.append(a)
                
        # Dijkstra Single Linkage
        def get_corners(box):
            if box.rect is not None:
                return [
                    (box.rect.topLeft_x, box.rect.topLeft_y),
                    (box.rect.topRight_x, box.rect.topRight_y),
                    (box.rect.bottomLeft_x, box.rect.bottomLeft_y),
                    (box.rect.bottomRight_x, box.rect.bottomRight_y)
                ]
            else:
                return [
                    (box.x, box.y),
                    (box.x + box.w, box.y),
                    (box.x, box.y + box.h),
                    (box.x + box.w, box.y + box.h)
                ]

        n_nodes = len(deskewed_boxes)
        corners_list = [get_corners(b) for b in deskewed_boxes]
        
        min_corner_dist = [[0.0] * n_nodes for _ in range(n_nodes)]
        adj = [[] for _ in range(n_nodes)]
        dist_threshold = 4.0 * median_height
        
        for i in range(n_nodes):
            for j in range(i+1, n_nodes):
                d_min = float("inf")
                for p1 in corners_list[i]:
                    for p2 in corners_list[j]:
                        d = math.sqrt((p1[0] - p2[0])**2 + (p1[1] - p2[1])**2)
                        if d < d_min: d_min = d
                min_corner_dist[i][j] = d_min
                min_corner_dist[j][i] = d_min
                
                if d_min < dist_threshold:
                    adj[i].append(j)
                    adj[j].append(i)
                    
        visited = [False] * n_nodes
        components = []
        for i in range(n_nodes):
            if not visited[i]:
                comp = []
                q = [i]
                visited[i] = True
                head = 0
                while head < len(q):
                    u = q[head]
                    head += 1
                    comp.append(u)
                    for v in adj[u]:
                        if not visited[v]:
                            visited[v] = True
                            q.append(v)
                components.append(comp)
                
        final_clusters = []
        for comp in components:
            comp_anchors = []
            for node in comp:
                b = deskewed_boxes[node]
                for anchor in cui_anchors:
                    if b.x == anchor.x and b.y == anchor.y and b.text == anchor.text:
                        comp_anchors.append(node)
                        break
            if len(comp_anchors) <= 1:
                final_clusters.append([deskewed_boxes[idx] for idx in comp])
            else:
                dist = {node: float("inf") for node in comp}
                owner = {node: -1 for node in comp}
                for m, anchor_node in enumerate(comp_anchors):
                    dist[anchor_node] = 0.0
                    owner[anchor_node] = m
                queue = set(comp)
                while queue:
                    u = min(queue, key=lambda node: dist[node])
                    queue.remove(u)
                    u_dist = dist[u]
                    u_owner = owner[u]
                    for v in adj[u]:
                        if v in queue:
                            weight = min_corner_dist[u][v]
                            alt = u_dist + weight
                            if alt < dist[v]:
                                dist[v] = alt
                                owner[v] = u_owner
                                
                partitioned = [[] for _ in range(len(comp_anchors))]
                for node in comp:
                    own = owner[node]
                    index = own if (0 <= own < len(comp_anchors)) else 0
                    partitioned[index].append(deskewed_boxes[node])
                for sub_comp in partitioned:
                    if sub_comp: final_clusters.append(sub_comp)
                    
        filtered = [c for c in final_clusters if len(c) >= 3]
        if not filtered: filtered = [deskewed_boxes]
        
        def compare_clusters(c1, c2):
            c1_x = [b.x for b in c1]
            c1_y = [b.y for b in c1]
            c2_x = [b.x for b in c2]
            c2_y = [b.y for b in c2]
            y1 = min(c1_y) if c1_y else 0.0
            y2 = min(c2_y) if c2_y else 0.0
            x1 = min(c1_x) if c1_x else 0.0
            x2 = min(c2_x) if c2_x else 0.0
            if abs(y1 - y2) < median_height * 5.0:
                return -1 if x1 < x2 else 1
            return -1 if y1 < y2 else 1
            
        import functools
        return sorted(filtered, key=functools.cmp_to_key(compare_clusters))


# --- ADVERSARIAL TEST SUITE ---

def run_adversarial_suite():
    print("=" * 70)
    print("RUNNING ADVERSARIAL TEST SUITE")
    print("=" * 70)

    orchestrator = AccountingOrchestrator(simulate_timeout=False, bnr_eur_rate=5.0)

    # ----------------------------------------------------
    # Case 1: Phone numbers containing valid CUIs
    # ----------------------------------------------------
    print("\n[TEST 1] Phone numbers containing valid CUIs...")
    # CUI checksum test: Let's find a 10-digit phone number starting with 07 that satisfies the CUI check.
    # The CUI algorithm reversed: control key "753217532"
    # We want a 10-digit number `07xxxxxxxx` which is valid as CUI.
    # Let's search for one programmatically:
    valid_phone_cui = None
    for suffix in range(10000000, 99999999):
        candidate = f"07{suffix}"
        # Wait, check if it's valid under standard Luhn checksum but starts with 07:
        if is_valid_cui(candidate):
            # Wait, is_valid_cui returns False for phone prefixes 07/02/03.
            # Let's verify our custom is_valid_cui correctly drops it.
            # We want to test that if a box has "TEL: 07{suffix}", we don't treat it as a seller CUI anchor or seller CUI, 
            # even though it might satisfy the base checksum if we ignored the prefix.
            # Let's check:
            # Let's calculate checksum for 07{suffix} without prefix check:
            control_key = "753217532"[::-1]
            cui_reversed = candidate[::-1]
            sum_val = sum(int(cui_reversed[i]) * int(control_key[i - 1]) for i in range(1, len(cui_reversed)))
            calc = (sum_val * 10) % 11
            ctrl = 0 if calc == 11 or calc == 10 else calc # wait, 0 if calc == 10 else calc
            if ctrl == int(cui_reversed[0]):
                valid_phone_cui = candidate
                break
                
    if valid_phone_cui:
        print(f"  Found mathematically valid phone-cui: {valid_phone_cui}")
        # Build boxes containing this number as a phone number
        p_boxes = [
            OCRBoxItem("S.C. PHONE STORE S.R.L.", 100, 100, 200, 20),
            OCRBoxItem("CIF:", 100, 130, 40, 20),
            OCRBoxItem("RO 8609468", 150, 130, 100, 20), # Real seller CUI
            OCRBoxItem("TEL:", 100, 160, 40, 20),
            OCRBoxItem(valid_phone_cui, 150, 160, 100, 20), # Valid checksum but starts with 07
            OCRBoxItem("TOTAL", 100, 200, 60, 20),
            OCRBoxItem("50.00", 170, 200, 60, 20),
        ]
        res = orchestrator.process_ocr_result(p_boxes)[0]
        print(f"  Extracted CUI: {res.cui} (expected: 8609468)")
        assert res.cui == "8609468", f"Failed: phone number {valid_phone_cui} was extracted as seller CUI!"
        print("  [PASS] Phone number was correctly ignored.")
    else:
        print("  [SKIP] Could not find mathematically valid phone-CUI.")

    # ----------------------------------------------------
    # Case 2: Rotated layout transformations
    # ----------------------------------------------------
    print("\n[TEST 2] Rotated layouts deskewing and clustering...")
    # Base layout coordinates (flat)
    # Receipt A: CUI=8609468, Total=119.00
    base_a = [
        ("S.C. MEGA IMAGE S.R.L.", 50, 50, 200, 20),
        ("CIF: RO 8609468", 50, 80, 150, 20),
        ("TVA 19%", 50, 110, 80, 20),
        ("19.00", 250, 110, 60, 20),
        ("TOTAL 119.00", 50, 140, 150, 20)
    ]
    # Receipt B: CUI=14399840, Total=200.00 (placed at x=550)
    base_b = [
        ("S.C. DANTE S.A.", 550, 50, 200, 20),
        ("CUI: 14399840", 550, 80, 150, 20),
        ("TOTAL 200.00", 550, 140, 150, 20)
    ]
    
    # Rotate by 30 degrees (0.52359877 rad) around center (400, 100)
    angle = 30.0 * math.pi / 180.0
    cx, cy = 400.0, 100.0
    rotated_boxes = []
    
    for text, x, y, w, h in base_a + base_b:
        # Rotate coordinates
        rx, ry = rotate_point(x, y, cx, cy, angle)
        # Create rotated rect
        rect = get_rotated_rect_container(x, y, w, h, angle, cx, cy)
        rotated_boxes.append(OCRBoxItem(text, rx, ry, w, h, rect))
        
    results = orchestrator.process_ocr_result(rotated_boxes)
    print(f"  Number of clusters extracted from rotated grid: {len(results)} (expected: 2)")
    assert len(results) == 2, f"Failed to cluster rotated grid, got {len(results)} clusters."
    
    # Verify values
    cuis = {r.cui for r in results}
    print(f"  Extracted CUIs: {cuis} (expected: {{'8609468', '14399840'}})")
    assert "8609468" in cuis and "14399840" in cuis, "Failed: missing expected CUIs in rotated layout test."
    print("  [PASS] Rotated layouts correctly deskewed, clustered, and processed.")

    # ----------------------------------------------------
    # Case 3: Thousands separators
    # ----------------------------------------------------
    print("\n[TEST 3] Thousands separators parsing...")
    formats = [
        ("1.234,56", 1234.56),
        ("1,234.56", 1234.56),
        ("1 234,56", 1234.56),
        ("1234.56", 1234.56)
    ]
    for fmt_str, expected_val in formats:
        val = parse_formatted_amount(fmt_str)
        print(f"  Format: '{fmt_str}' -> Parsed: {val} (expected: {expected_val})")
        assert val == expected_val, f"Failed to parse format '{fmt_str}', got {val}"
    print("  [PASS] All thousands separator formats parsed correctly.")

    # ----------------------------------------------------
    # Case 4: Pre-2025 receipts vs 2026 receipts (2-digit year bug check)
    # ----------------------------------------------------
    print("\n[TEST 4] Pre-2025 receipts vs 2026 receipts...")
    
    # Sub-case A: Pre-2025 receipt (2024). Should NOT correct VAT rate.
    print("  Sub-case A: Receipt dated 12.12.2024 (4-digit) with 19% VAT")
    boxes_2024 = [
        OCRBoxItem("S.C. MEGA IMAGE S.R.L.", 100, 100, 200, 20),
        OCRBoxItem("CIF: RO 8609468", 100, 130, 150, 20),
        OCRBoxItem("DATA: 12.12.2024", 100, 160, 150, 20),
        OCRBoxItem("TVA 19%", 100, 190, 80, 20),
        OCRBoxItem("19.00", 250, 190, 60, 20),
        OCRBoxItem("TOTAL 119.00", 100, 220, 150, 20)
    ]
    res_2024 = orchestrator.process_ocr_result(boxes_2024)[0]
    print(f"    VAT Rate: {res_2024.vatPercentages} (expected: 19%), Total: {res_2024.totalAmount}, VAT: {res_2024.vatAmount}")
    assert res_2024.vatPercentages == "19%", f"Failed: 2024 receipt had VAT corrected to {res_2024.vatPercentages}"
    assert "Corecție automată" not in "".join(res_2024.fiscalWarnings), "Failed: 2024 receipt contains correction warning."
    
    # Sub-case B: 2026 receipt (4-digit year). Should correct 19% -> 21%.
    print("  Sub-case B: Receipt dated 12.12.2026 (4-digit) with 19% VAT")
    boxes_2026 = [
        OCRBoxItem("S.C. MEGA IMAGE S.R.L.", 100, 100, 200, 20),
        OCRBoxItem("CIF: RO 8609468", 100, 130, 150, 20),
        OCRBoxItem("DATA: 12.12.2026", 100, 160, 150, 20),
        OCRBoxItem("TVA 19%", 100, 190, 80, 20),
        OCRBoxItem("19.00", 250, 190, 60, 20),
        OCRBoxItem("TOTAL 119.00", 100, 220, 150, 20)
    ]
    res_2026 = orchestrator.process_ocr_result(boxes_2026)[0]
    print(f"    VAT Rate: {res_2026.vatPercentages} (expected: 21%), Total: {res_2026.totalAmount}, VAT: {res_2026.vatAmount}")
    assert res_2026.vatPercentages == "21%", f"Failed: 2026 receipt did not correct VAT rate, got {res_2026.vatPercentages}"
    assert any("Corecție" in w for w in res_2026.fiscalWarnings), "Failed: 2026 receipt missing correction warning."

    # Sub-case C: 2026 receipt with 2-digit year format (e.g. '26').
    # Due to the Swift implementation bug, '26' is parsed as 1926 (<= 2024) instead of 2026.
    # Therefore, VAT correction is NOT applied! Let's verify if our simulator catches this bug.
    print("  Sub-case C: Receipt dated 12.12.26 (2-digit) with 19% VAT (BUG VERIFICATION)")
    boxes_2026_short = [
        OCRBoxItem("S.C. MEGA IMAGE S.R.L.", 100, 100, 200, 20),
        OCRBoxItem("CIF: RO 8609468", 100, 130, 150, 20),
        OCRBoxItem("DATA: 12.12.26", 100, 160, 150, 20),
        OCRBoxItem("TVA 19%", 100, 190, 80, 20),
        OCRBoxItem("19.00", 250, 190, 60, 20),
        OCRBoxItem("TOTAL 119.00", 100, 220, 150, 20)
    ]
    res_2026_short = orchestrator.process_ocr_result(boxes_2026_short)[0]
    print(f"    VAT Rate: {res_2026_short.vatPercentages} (Actual output: {res_2026_short.vatPercentages})")
    
    # We expect this to fail correction due to the bug. Let's document this behavior.
    if res_2026_short.vatPercentages == "19%":
        print("    [BUG CONFIRMED] VAT correction was bypassed for year '26' because it parsed to 1926!")
    else:
        print("    [INFO] VAT correction applied (no bug or bug fixed).")

    print("\n" + "=" * 70)
    print("ALL ADVERSARIAL TESTS COMPLETED")
    print("=" * 70)

if __name__ == "__main__":
    run_adversarial_suite()
