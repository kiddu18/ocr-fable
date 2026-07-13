import re
from functools import cmp_to_key
import math

class OCRBoxItem:
    def __init__(self, text: str, x: float, y: float, w: float, h: float):
        self.text = text
        self.x = x
        self.y = y
        self.w = w
        self.h = h

    def __repr__(self):
        return f"OCRBoxItem(text={repr(self.text)}, x={self.x}, y={self.y}, w={self.w}, h={self.h})"


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

    @property
    def globalRequiresManualVerification(self):
        return (self.documentTypeRequiresVerification or 
                self.cuiRequiresVerification or 
                self.totalRequiresVerification or 
                self.vatRequiresVerification or 
                len(self.fiscalWarnings) > 0)

    def __repr__(self):
        return (f"AccountingResult(type={self.documentType}, typeVerify={self.documentTypeRequiresVerification}, "
                f"series={self.documentSeries}, number={self.documentNumber}, date={self.documentDate}, "
                f"cui={self.cui}, cuiVerify={self.cuiRequiresVerification}, name={self.companyName}, "
                f"total={self.totalAmount}, totalVerify={self.totalRequiresVerification}, "
                f"vat={self.vatAmount}, vatVerify={self.vatRequiresVerification}, pct={self.vatPercentages}, "
                f"base={self.baseAmount}, warnings={self.fiscalWarnings})")


# --- Fuzzy String Matching (Levenshtein) ---
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


# --- CUI Helper functions ---
def is_valid_cui(cui: str) -> bool:
    if not (4 <= len(cui) <= 10):
        return False
    if not cui.isdigit():
        return False
    # Ignore 10-digit numbers starting with "07", "02", or "03" (phone numbers)
    if len(cui) == 10 and (cui.startswith("07") or cui.startswith("02") or cui.startswith("03")):
        return False
        
    control_key = "753217532"
    control_key_reversed = control_key[::-1]
    cui_reversed = cui[::-1]
    
    sum_val = 0
    control_digit = int(cui_reversed[0])
    
    for i in range(1, len(cui_reversed)):
        if i - 1 < len(control_key_reversed):
            c_num = int(cui_reversed[i])
            k_num = int(control_key_reversed[i - 1])
            sum_val += c_num * k_num
            
    calc_control_digit = (sum_val * 10) % 11
    final_control_digit = 0 if calc_control_digit == 10 else calc_control_digit
    
    return final_control_digit == control_digit


def verify_with_anaf(cui: str, result: AccountingResult, simulate_timeout: bool = False):
    if simulate_timeout:
        result.cuiRequiresVerification = True
        return
        
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
        if not result.cuiRequiresVerification:
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
        full_text = "\n".join(text_blocks).upper()
        
        series_pattern = r"(?:SERIA|SERIE|SERIA:|CHITANTA\s*SERIA)\s*([A-Z]{1,5})"
        match = re.search(series_pattern, full_text)
        if match:
            result.documentSeries = match.group(1).strip()
            
        number_pattern = r"(?:NR\.?|NUMAR|BON\s*NR\.?|FACTURA\s*NR\.?|CHITANTA\s*NR\.?|BF\.?)\s*[:]*\s*([0-9]{1,10})"
        match = re.search(number_pattern, full_text)
        if match:
            result.documentNumber = match.group(1).strip()
            
        date_pattern = r"(?:DATA\s*[:]*\s*)?([0-3][0-9][\.\-\/][0-1][0-9][\.\-\/]20[0-9]{2})"
        match = re.search(date_pattern, full_text)
        if match:
            result.documentDate = match.group(1).strip()


def is_buyer_cui_box(box, boxes, median_height):
    text = box.text.upper()
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
        if other.x == box.x and other.y == box.y:
            continue
        other_text = other.text.upper()
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
        
        dy = box.y - other.y
        dx = box.x - other.x
        
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

class CuiExtractorAgent:
    def __init__(self, simulate_timeout: bool = False):
        self.simulate_timeout = simulate_timeout
        
    def process(self, text_blocks, boxes, result):
        sorted_heights = sorted([b.h for b in boxes])
        median_height = sorted_heights[len(sorted_heights) // 2] if sorted_heights else 15.0

        # 1. Cautare Spatiala Inteligenta 2D (Fuzzy)
        cui_keywords = ["CIF", "CUI", "CODFISCAL", "R0", "IDENTIFICARE"]
        candidate_boxes = []
        
        for box in boxes:
            if is_buyer_cui_box(box, boxes, median_height):
                continue
            if is_phone_or_phone_label(box, boxes, median_height):
                continue
            clean_text = box.text.upper().replace(".", "").replace(" ", "")
            if "CLIENT" in clean_text or "CUMP" in clean_text or "BENEF" in clean_text or "CNP" in clean_text:
                continue
            is_cand = any(kw in clean_text or (len(clean_text) <= len(kw) + 2 and is_fuzzy_match(clean_text, kw, 1)) for kw in cui_keywords)
            if not is_cand:
                is_cand = contains_refined_ro(box.text)
            if is_cand:
                candidate_boxes.append(box)
                
        # Verificam textul din interiorul cutiilor gasite (poate CUI-ul e in aceeasi cutie: "CIF RO123456")
        for box in candidate_boxes:
            if "%" in box.text:
                continue
            if is_buyer_cui_box(box, boxes, median_height):
                continue
            if is_phone_or_phone_label(box, boxes, median_height):
                continue
            cleaned = clean_fallback_candidate(box.text)
            if cleaned and cleaned.isdigit() and is_valid_cui(cleaned):
                result.cui = cleaned
                result.cuiRequiresVerification = False
                verify_with_anaf(cleaned, result, self.simulate_timeout)
                result.cui = cleaned
                return
                
        # Cautam cutii la dreapta sau putin mai jos
        for keyword_box in candidate_boxes:
            nearby_boxes = [
                b for b in boxes
                if (b.x != keyword_box.x or b.y != keyword_box.y) and
                b.y >= keyword_box.y - keyword_box.h * 0.8 and
                b.y <= keyword_box.y + keyword_box.h * 2.0 and
                b.x >= keyword_box.x - keyword_box.w * 0.5
            ]
            nearby_boxes.sort(key=lambda b: b.x)
            
            for nb in nearby_boxes:
                if "%" in nb.text:
                    continue
                if is_buyer_cui_box(nb, boxes, median_height):
                    continue
                if is_phone_or_phone_label(nb, boxes, median_height):
                    continue
                cleaned = clean_fallback_candidate(nb.text)
                if cleaned and cleaned.isdigit() and is_valid_cui(cleaned):
                    result.cui = cleaned
                    result.cuiRequiresVerification = False
                    verify_with_anaf(cleaned, result, self.simulate_timeout)
                    result.cui = cleaned
                    return
                    
        # 2. Fallback la Regex-ul clasic
        buyer_texts = [b.text.upper() for b in boxes if is_buyer_cui_box(b, boxes, median_height)]
        cui_text_blocks = []
        for block in text_blocks:
            block_text = block
            for bt in buyer_texts:
                if bt in block_text.upper():
                    block_text = re.sub(re.escape(bt), "", block_text, flags=re.IGNORECASE)
            cui_text_blocks.append(block_text)
        full_text = " ".join(cui_text_blocks).upper()
        fallback_pattern = r"\b([0-9]{2,10})\b"
        matches = re.finditer(fallback_pattern, full_text)
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
                
            # Check if this candidate is a buyer CUI or phone
            is_buyer_or_phone = False
            for box in boxes:
                if cui_candidate in box.text.replace(" ", ""):
                    if is_buyer_cui_box(box, boxes, median_height) or is_phone_or_phone_label(box, boxes, median_height):
                        is_buyer_or_phone = True
                        break
            if is_buyer_or_phone:
                continue
                
            if is_valid_cui(cui_candidate):
                result.cui = cui_candidate
                result.cuiRequiresVerification = False
                verify_with_anaf(cui_candidate, result, self.simulate_timeout)
                result.cui = cui_candidate
                return
                
        # 3. Fallback: extractia de secvente alfanumerice din vecinatate (lungime 2-12)
        fallback_candidates = []
        for box in candidate_boxes:
            if is_buyer_cui_box(box, boxes, median_height):
                continue
            if is_phone_or_phone_label(box, boxes, median_height):
                continue
            cleaned = clean_fallback_candidate(box.text)
            if cleaned:
                fallback_candidates.append((cleaned, 0.0))
                
        for keyword_box in candidate_boxes:
            nearby_boxes = [
                b for b in boxes
                if (b.x != keyword_box.x or b.y != keyword_box.y) and
                b.y >= keyword_box.y - keyword_box.h * 1.5 and
                b.y <= keyword_box.y + keyword_box.h * 3.0 and
                b.x >= keyword_box.x - keyword_box.w * 0.5
            ]
            for nb in nearby_boxes:
                if "%" in nb.text:
                    continue
                if is_buyer_cui_box(nb, boxes, median_height):
                    continue
                if is_phone_or_phone_label(nb, boxes, median_height):
                    continue
                cleaned = clean_fallback_candidate(nb.text)
                if cleaned:
                    dx = nb.x - keyword_box.x
                    dy = nb.y - keyword_box.y
                    import math
                    dist = math.sqrt(dx*dx + dy*dy)
                    fallback_candidates.append((cleaned, dist))
                    
        if fallback_candidates:
            fallback_candidates.sort(key=lambda x: x[1])
            best_candidate = fallback_candidates[0][0]
            result.cui = best_candidate
            result.cuiRequiresVerification = True
            verify_with_anaf(best_candidate, result, self.simulate_timeout)
            result.cui = best_candidate
            return
            
        result.cuiRequiresVerification = True


class FinancialAmountsAgent:
    def process(self, text_blocks, boxes, result):
        full_text = "\n".join(text_blocks).upper()
        
        # --- SPATIAL TOTAL EXTRACTION ---
        total_keywords = ["TOTAL", "SUMA", "ACHITAT"]
        total_found = False
        
        for box in boxes:
            clean_text = box.text.upper().replace(" ", "").replace(":", "")
            if "SUBTOTAL" in clean_text:
                continue
            if any(kw in clean_text or (len(clean_text) <= len(kw) + 2 and is_fuzzy_match(clean_text, kw, 1)) for kw in total_keywords):
                y_tol = max(box.h * 0.6, 15.0)
                line_boxes = [
                    b for b in boxes
                    if (b.x != box.x or b.y != box.y) and
                    abs(b.y - box.y) < y_tol and
                    b.x > box.x - box.w * 0.5
                ]
                line_boxes.sort(key=lambda b: b.x)
                
                line_text_for_check = " ".join([b.text.upper() for b in line_boxes]) + " " + box.text.upper()
                if any(kw in line_text_for_check for kw in ["TVA", "TAXA", "TAXE"]):
                    continue  # Ignoram liniile "TOTAL TVA", "TAXA", "TAXE"
                
                # Check individual boxes
                for l_box in line_boxes:
                    pattern = r"([0-9]{1,3}(?:[.,\s][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?)"
                    match = re.search(pattern, l_box.text)
                    if match:
                        val = parse_formatted_amount(match.group(1))
                        if val is not None and val > 1.0:
                            if val in [21.0, 19.0, 11.0, 9.0, 5.0]:
                                continue
                            result.totalAmount = val
                            result.totalRequiresVerification = False
                            total_found = True
                            break
            if total_found:
                break
                
        # Fallback TOTAL
        if not total_found:
            total_pattern = r"(?i)(?:TOTAL|SUMA|ACHITAT)[ \t]*(?:LEI)?[ \t]*[:=]*[ \t]*([0-9]{1,3}(?:[.,\s][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?)"
            match = re.search(total_pattern, full_text)
            if match:
                val = parse_formatted_amount(match.group(1))
                if val is not None:
                    result.totalAmount = val
                    result.totalRequiresVerification = False
                    total_found = True
                
        # Ultimul Fallback: ia cel mai mare numar
        if result.totalAmount is None:
            cui_float = None
            if result.cui:
                clean_cui = "".join(c for c in result.cui if c.isdigit())
                if clean_cui:
                    try:
                        cui_float = float(clean_cui)
                    except ValueError:
                        pass
            pattern = r"(?<!%)\b([0-9]{1,3}(?:[.,\s][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?)\b(?!\s*%)"
            matches = re.finditer(pattern, full_text)
            amounts = []
            for m in matches:
                val = parse_formatted_amount(m.group(1))
                if val is not None and val != cui_float:
                    if val not in [24.0, 21.0, 19.0, 11.0, 9.0, 5.0, 0.0]:
                        amounts.append(val)
            amounts.sort(reverse=True)
            if amounts:
                result.totalAmount = amounts[0]
                result.totalRequiresVerification = True
                
        is_receipt = result.documentType in ["Chitanță POS", "Chitanță de mână"]
        
        if is_receipt:
            result.vatAmount = 0.0
            result.vatPercentages = "-"
            result.baseAmount = result.totalAmount
            result.vatRequiresVerification = False
        else:
            # --- SPATIAL TVA EXTRACTION ---
            found_vat_amounts = []
            found_vat_percentages = []
            
            for box in boxes:
                clean_text = box.text.upper().replace(" ", "").replace(":", "")
                if is_fuzzy_match(clean_text, "TVA", 1) or "TVA" in clean_text:
                    y_tol = max(box.h * 0.6, 15.0)
                    line_boxes = [
                        b for b in boxes
                        if (b.x != box.x or b.y != box.y) and
                        abs(b.y - box.y) < y_tol and
                        b.x > box.x - box.w * 0.5
                    ]
                    line_boxes.sort(key=lambda b: b.x)
                    
                    line_text = " ".join([b.text for b in line_boxes])
                    vat_pattern = r"([0-9]{1,2})(?:[,.][0-9]{1,2})?\s*%\D{0,15}?([0-9]{1,3}(?:[.,\s][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?)"
                    match = re.search(vat_pattern, line_text)
                    if match:
                        pct_string = match.group(1)
                        val_string = match.group(2)
                        val = parse_formatted_amount(val_string)
                        if val is not None:
                            found_vat_percentages.append(f"{pct_string}%")
                            found_vat_amounts.append(val)
            
            # Fallback TVA
            if not found_vat_amounts:
                total_vat_pattern = r"TOTAL\s*TVA\D{0,15}?([0-9]{1,3}(?:[.,\s][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?)"
                match = re.search(total_vat_pattern, full_text)
                if match:
                    val_string = match.group(1)
                    val = parse_formatted_amount(val_string)
                    if val is not None:
                        found_vat_amounts.append(val)
                        found_vat_percentages.append("Mixt")
            
            if found_vat_amounts:
                sum_vat = sum(found_vat_amounts)
                result.vatAmount = round(sum_vat, 2)
                result.vatPercentages = ", ".join(sorted(list(set(found_vat_percentages))))
                result.vatRequiresVerification = False
                
                if result.totalAmount is not None:
                    result.baseAmount = round(result.totalAmount - result.vatAmount, 2)
                
                # Populate breakdowns
                result.vatBreakdowns = []
                for pct, vat in zip(found_vat_percentages, found_vat_amounts):
                    rate = float(pct.replace("%", "")) if "%" in pct else 19.0
                    base = round(vat / (rate / 100.0), 2)
                    if result.totalAmount is not None and len(found_vat_amounts) == 1:
                        base = round(result.totalAmount - vat, 2)
                    result.vatBreakdowns.append({
                        "percentage": pct,
                        "vatAmount": vat,
                        "baseAmount": base
                    })
            else:
                result.vatAmount = 0.0
                result.vatPercentages = "-"
                result.baseAmount = result.totalAmount


class FiscalComplianceAgent:
    def __init__(self, buyer_cui: str = None, bnr_eur_rate: float = 5.0):
        self.buyer_cui = buyer_cui
        self.bnr_eur_rate = bnr_eur_rate
        
    def process(self, text_blocks, boxes, result):
        full_text = " ".join(text_blocks).upper()
        
        if result.documentType == "Bon Fiscal":
            if self.buyer_cui and self.buyer_cui.strip():
                b_cui_clean = self.buyer_cui.replace(" ", "").upper()
                full_text_clean = full_text.replace(" ", "")
                if b_cui_clean not in full_text_clean:
                    result.fiscalWarnings.append(f"Atenție: Bonul fiscal nu conține CUI-ul cumpărătorului ({self.buyer_cui}). TVA-ul este complet nedeductibil!")
                    result.documentTypeRequiresVerification = True
            else:
                result.fiscalWarnings.append("Sfat: Introduceți CUI-ul clientului pentru a verifica deductibilitatea bonului.")
                
            if result.totalAmount is not None:
                limit_ron = self.bnr_eur_rate * 100.0
                if result.totalAmount > limit_ron:
                    result.fiscalWarnings.append(f"Atenție: Bonul fiscal depășește limita de ~100 EUR ({limit_ron:.2f} RON) pentru a fi considerat factură simplificată.")
                    result.totalRequiresVerification = True
                    
        elif result.documentType == "Factură":
            has_seria = "SERIA" in full_text or "SERIE" in full_text
            has_numar = "NR." in full_text or "NUMAR" in full_text or "NO." in full_text
            
            if not has_seria and not has_numar:
                result.fiscalWarnings.append("Atenție: Documentul a fost clasificat ca Factură, dar nu conține elemente obligatorii clare (Seria / Numărul).")
                result.documentTypeRequiresVerification = True


def extract_cui(text: str):
    clean = text.upper().replace(" ", "").replace(".", "").replace(":", "").replace("-", "")
    matches = re.findall(r"\d{2,10}", clean)
    for candidate in matches:
        if is_valid_cui(candidate):
            return candidate
    return None

def get_box_properties(box):
    if isinstance(box, dict):
        x = box["x"]
        y = box["y"]
        w = box["w"]
        h = box["h"]
        text = box["text"]
        rect = box.get("rect", None)
    else:
        x = box.x
        y = box.y
        w = box.w
        h = box.h
        text = box.text
        rect = getattr(box, "rect", None)
    return x, y, w, h, text, rect

def get_corners(box):
    x, y, w, h, text, rect = get_box_properties(box)
    if rect is not None:
        if isinstance(rect, dict):
            return [
                (rect.get("topLeft_x", x), rect.get("topLeft_y", y)),
                (rect.get("topRight_x", x+w), rect.get("topRight_y", y)),
                (rect.get("bottomLeft_x", x), rect.get("bottomLeft_y", y+h)),
                (rect.get("bottomRight_x", x+w), rect.get("bottomRight_y", y+h))
            ]
        else:
            return [
                (getattr(rect, "topLeft_x", x), getattr(rect, "topLeft_y", y)),
                (getattr(rect, "topRight_x", x+w), getattr(rect, "topRight_y", y)),
                (getattr(rect, "bottomLeft_x", x), getattr(rect, "bottomLeft_y", y+h)),
                (getattr(rect, "bottomRight_x", x+w), getattr(rect, "bottomRight_y", y+h))
            ]
    else:
        return [
            (x, y),
            (x + w, y),
            (x, y + h),
            (x + w, y + h)
        ]


# --- AccountingOrchestrator ---

class AccountingOrchestrator:
    def __init__(self, simulate_timeout: bool = False, bnr_eur_rate: float = 5.0):
        self.simulate_timeout = simulate_timeout
        self.bnr_eur_rate = bnr_eur_rate
        
    def process_ocr_result(self, boxes, buyer_cui: str = None) -> list:
        text_blocks = []
        sorted_by_y = sorted(boxes, key=lambda b: b.y)
        if sorted_by_y:
            lines = []
            current_line = [sorted_by_y[0]]
            sorted_heights = sorted([b.h for b in sorted_by_y])
            median_height = sorted_heights[len(sorted_heights) // 2]
            y_tolerance = median_height * 0.4
            
            for box in sorted_by_y[1:]:
                if abs(box.y - current_line[0].y) < y_tolerance:
                    current_line.append(box)
                else:
                    lines.append(current_line)
                    current_line = [box]
            lines.append(current_line)
            
            text_blocks = []
            for line in lines:
                sorted_line = sorted(line, key=lambda b: b.x)
                text_blocks.append(" ".join([b.text for b in sorted_line]))
                
        result = AccountingResult()
        
        agents = [
            DocumentClassificationAgent(),
            DocumentDetailsAgent(),
            CuiExtractorAgent(simulate_timeout=self.simulate_timeout),
            FinancialAmountsAgent(),
            FiscalComplianceAgent(buyer_cui=buyer_cui, bnr_eur_rate=self.bnr_eur_rate)
        ]
        
        for agent in agents:
            agent.process(text_blocks, boxes, result)
            
        # --- SPLIT LOGIC ---
        if result.vatBreakdowns and len(result.vatBreakdowns) > 0:
            import copy
            split_results = []
            for b in result.vatBreakdowns:
                split_copy = copy.deepcopy(result)
                split_copy.vatPercentages = b["percentage"]
                split_copy.vatAmount = b["vatAmount"]
                split_copy.baseAmount = b["baseAmount"]
                split_copy.totalAmount = round(b["baseAmount"] + b["vatAmount"], 2) if len(result.vatBreakdowns) > 1 else (result.totalAmount if result.totalAmount is not None else round(b["baseAmount"] + b["vatAmount"], 2))
                split_copy.vatBreakdowns = None
                split_results.append(split_copy)
            return split_results
            
        return [result]

    def cluster_boxes(self, boxes):
        if len(boxes) <= 1:
            return [boxes]
        
        # === 1. Skew Angle & Deskewing ===
        angles = []
        for box in boxes:
            x, y, w, h, text, rect = get_box_properties(box)
            if rect is not None:
                if isinstance(rect, dict):
                    tr_y, tl_y = rect.get("topRight_y", y), rect.get("topLeft_y", y)
                    tr_x, tl_x = rect.get("topRight_x", x+w), rect.get("topLeft_x", x)
                else:
                    tr_y, tl_y = getattr(rect, "topRight_y", y), getattr(rect, "topLeft_y", y)
                    tr_x, tl_x = getattr(rect, "topRight_x", x+w), getattr(rect, "topLeft_x", x)
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
            x, y, w, h, text, rect = get_box_properties(box)
            cx = x + w / 2.0
            cy = y + h / 2.0
            cx_prime = cx * cos_t - cy * sin_t
            cy_prime = cx * sin_t + cy * cos_t
            new_x = cx_prime - w / 2.0
            new_y = cy_prime - h / 2.0
            
            new_rect = None
            if rect is not None:
                if isinstance(rect, dict):
                    tl_x, tl_y = rect.get("topLeft_x", x), rect.get("topLeft_y", y)
                    tr_x, tr_y = rect.get("topRight_x", x+w), rect.get("topRight_y", y)
                    bl_x, bl_y = rect.get("bottomLeft_x", x), rect.get("bottomLeft_y", y+h)
                    br_x, br_y = rect.get("bottomRight_x", x+w), rect.get("bottomRight_y", y+h)
                else:
                    tl_x, tl_y = getattr(rect, "topLeft_x", x), getattr(rect, "topLeft_y", y)
                    tr_x, tr_y = getattr(rect, "topRight_x", x+w), getattr(rect, "topRight_y", y)
                    bl_x, bl_y = getattr(rect, "bottomLeft_x", x), getattr(rect, "bottomLeft_y", y+h)
                    br_x, br_y = getattr(rect, "bottomRight_x", x+w), getattr(rect, "bottomRight_y", y+h)
                    
                new_rect = {
                    "topLeft_x": tl_x * cos_t - tl_y * sin_t,
                    "topLeft_y": tl_x * sin_t + tl_y * cos_t,
                    "topRight_x": tr_x * cos_t - tr_y * sin_t,
                    "topRight_y": tr_x * sin_t + tr_y * cos_t,
                    "bottomLeft_x": bl_x * cos_t - bl_y * sin_t,
                    "bottomLeft_y": bl_x * sin_t + bl_y * cos_t,
                    "bottomRight_x": br_x * cos_t - br_y * sin_t,
                    "bottomRight_y": br_x * sin_t + br_y * cos_t
                }
                
            if isinstance(box, dict):
                db = {"text": text, "x": new_x, "y": new_y, "w": w, "h": h}
                if new_rect is not None:
                    db["rect"] = new_rect
            else:
                db = OCRBoxItem(text, new_x, new_y, w, h)
                if new_rect is not None:
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
                    db.rect = RectContainer(new_rect)
            deskewed_boxes.append(db)
            
        sorted_heights = sorted([get_box_properties(b)[3] for b in deskewed_boxes])
        median_height = sorted_heights[len(sorted_heights) // 2]
        
        # === 2. Identify CUI/CIF Anchors (using deskewed coordinates) ===
        def is_buyer_text(txt):
            t = txt.upper()
            return any(kw in t for kw in ["CLIENT", "CUMP", "BENEF", "CNP"])
            
        def is_cui_anchor(b):
            bx, by, bw, bh, btext, brect = get_box_properties(b)
            if is_buyer_text(btext): return False
            if "%" in btext: return False
            
            seller_keywords = ["CIF", "CUI", "CODFISCAL", "FISCAL", "COD FISCAL"]
            clean_text = btext.upper().replace(".", "").replace(" ", "")
            for kw in seller_keywords:
                if kw.replace(" ", "") in clean_text:
                    return True
                    
            cui = extract_cui(btext)
            if cui:
                if not is_buyer_cui_box(b, deskewed_boxes, median_height):
                    return True
            return False
            
        raw_anchors = [b for b in deskewed_boxes if is_cui_anchor(b)]
        cui_anchors = []
        for a in raw_anchors:
            ax, ay, aw, ah, atext, _ = get_box_properties(a)
            is_dup = False
            for u in cui_anchors:
                ux, uy, uw, uh, utext, _ = get_box_properties(u)
                dx = abs(ux - ax)
                dy = abs(uy - ay)
                if dx < median_height * 5.0 and dy < median_height * 3.0:
                    is_dup = True
                    break
            if not is_dup:
                cui_anchors.append(a)
                
        # === 3. Graph-Based (Single-Linkage) Clustering ===
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
                        if d < d_min:
                            d_min = d
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
                
        # === 4. Partition components with multiple anchors using Dijkstra ===
        final_clusters = []
        for comp in components:
            comp_anchors = []
            for node in comp:
                b = deskewed_boxes[node]
                bx, by, bw, bh, btext, _ = get_box_properties(b)
                for anchor in cui_anchors:
                    ax, ay, aw, ah, atext, _ = get_box_properties(anchor)
                    if bx == ax and by == ay and btext == atext:
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
                    if sub_comp:
                        final_clusters.append(sub_comp)
                        
        filtered_clusters = [c for c in final_clusters if len(c) >= 3]
        if not filtered_clusters:
            filtered_clusters = [deskewed_boxes]
            
        def compare_clusters(c1, c2):
            c1_x = [get_box_properties(b)[0] for b in c1]
            c1_y = [get_box_properties(b)[1] for b in c1]
            c2_x = [get_box_properties(b)[0] for b in c2]
            c2_y = [get_box_properties(b)[1] for b in c2]
            
            y1 = min(c1_y) if c1_y else 0.0
            y2 = min(c2_y) if c2_y else 0.0
            x1 = min(c1_x) if c1_x else 0.0
            x2 = min(c2_x) if c2_x else 0.0
            
            if abs(y1 - y2) < median_height * 5.0:
                return -1 if x1 < x2 else 1
            return -1 if y1 < y2 else 1
            
        import functools
        return sorted(filtered_clusters, key=functools.cmp_to_key(compare_clusters))


# --- TEST RUNNER ---

def run_tests():
    print("=" * 60)
    print("RUNNING SPATIAL OCR PARSING SIMULATOR TESTS")
    print("=" * 60)
    
    # ----------------------------------------------------
    # Scenario 1: Happy Path (Standard Receipt)
    # ----------------------------------------------------
    print("\nScenario 1: Happy Path (Standard Receipt)...")
    s1_boxes = [
        OCRBoxItem("S.C. MEGA IMAGE S.R.L.", 100, 100, 200, 20),
        OCRBoxItem("CIF:", 100, 130, 40, 20),
        OCRBoxItem("RO", 150, 130, 30, 20),
        OCRBoxItem("8609468", 190, 130, 100, 20),
        OCRBoxItem("TVA", 100, 160, 40, 20),
        OCRBoxItem("19%", 150, 160, 40, 20),
        OCRBoxItem("19.00", 200, 160, 60, 20),
        OCRBoxItem("TOTAL", 100, 190, 60, 20),
        OCRBoxItem("119.00", 170, 190, 60, 20),
    ]
    orchestrator = AccountingOrchestrator(simulate_timeout=False, bnr_eur_rate=5.0)
    res1 = orchestrator.process_ocr_result(s1_boxes)[0]
    
    print(res1)
    assert res1.cui == "8609468", f"Expected CUI 8609468, got {res1.cui}"
    assert res1.totalAmount == 119.00, f"Expected total 119.00, got {res1.totalAmount}"
    assert res1.vatAmount == 19.00, f"Expected VAT 19.00, got {res1.vatAmount}"
    assert res1.vatPercentages == "19%", f"Expected VAT Percentages '19%', got {res1.vatPercentages}"
    assert res1.baseAmount == 100.00, f"Expected baseAmount 100.00, got {res1.baseAmount}"
    assert res1.cuiRequiresVerification is False, "Expected cuiRequiresVerification to be False"
    print("Scenario 1 PASSED.")

    # ----------------------------------------------------
    # Scenario 2: CUI Override and Compliance Logic
    # ----------------------------------------------------
    print("\nScenario 2: CUI Override and Compliance Logic...")
    s2_boxes = [
        OCRBoxItem("S.C. DANTE INTERNATIONAL S.A.", 100, 100, 250, 20),
        OCRBoxItem("CIF:", 100, 130, 40, 20),
        OCRBoxItem("RO", 150, 130, 30, 20),
        OCRBoxItem("14399840", 190, 130, 100, 20),
        OCRBoxItem("CUI CUMPARATOR:", 100, 160, 150, 20),
        OCRBoxItem("RO", 260, 160, 30, 20),
        OCRBoxItem("8609468", 300, 160, 100, 20),
        OCRBoxItem("TOTAL", 100, 190, 60, 20),
        OCRBoxItem("100.00", 170, 190, 60, 20),
        OCRBoxItem("BON FISCAL", 100, 220, 100, 20),
    ]
    
    # Case A: Match
    print("  Sub-case: Match Case (buyerCui = 8609468)")
    res2_match = orchestrator.process_ocr_result(s2_boxes, buyer_cui="8609468")[0]
    print(res2_match)
    assert res2_match.cui == "14399840", f"Expected CUI 14399840, got {res2_match.cui}"
    # Verify no buyer CUI mismatch warnings
    mismatch_warnings = [w for w in res2_match.fiscalWarnings if "CUI-ul cumpărătorului" in w]
    assert len(mismatch_warnings) == 0, f"Expected no mismatch warnings, got {mismatch_warnings}"
    
    # Case B: Mismatch
    print("  Sub-case: Mismatch Case (buyerCui = 2816464)")
    res2_mismatch = orchestrator.process_ocr_result(s2_boxes, buyer_cui="2816464")[0]
    print(res2_mismatch)
    assert res2_mismatch.cui == "14399840", f"Expected CUI 14399840, got {res2_mismatch.cui}"
    mismatch_warnings = [w for w in res2_mismatch.fiscalWarnings if "CUI-ul cumpărătorului" in w]
    assert len(mismatch_warnings) > 0, "Expected mismatch warning but found none"
    expected_warning = "Atenție: Bonul fiscal nu conține CUI-ul cumpărătorului (2816464). TVA-ul este complet nedeductibil!"
    assert mismatch_warnings[0] == expected_warning, f"Expected warning '{expected_warning}', got '{mismatch_warnings[0]}'"
    print("Scenario 2 PASSED.")

    # ----------------------------------------------------
    # Scenario 3: TOTAL TVA Discrimination
    # ----------------------------------------------------
    print("\nScenario 3: TOTAL TVA Discrimination...")
    s3_boxes = [
        OCRBoxItem("SUBTOTAL", 100, 100, 100, 20),
        OCRBoxItem("50.00", 220, 100, 60, 20),
        OCRBoxItem("TOTAL", 100, 130, 60, 20),
        OCRBoxItem("TVA", 170, 130, 40, 20),
        OCRBoxItem("A - 19%", 220, 130, 80, 20),
        OCRBoxItem("9.50", 310, 130, 50, 20),
        OCRBoxItem("TOTAL", 100, 160, 60, 20),
        OCRBoxItem("59.50", 170, 160, 60, 20),
    ]
    res3 = orchestrator.process_ocr_result(s3_boxes)[0]
    print(res3)
    assert res3.totalAmount == 59.50, f"Expected total 59.50, got {res3.totalAmount}"
    print("Scenario 3 PASSED.")

    # ----------------------------------------------------
    # Scenario 4: Dynamic yTol Alignment
    # ----------------------------------------------------
    print("\nScenario 4: Dynamic yTol Alignment...")
    
    # Sub-case A: Large Title (Success)
    print("  Sub-case A: Large Title")
    s4a_boxes = [
        OCRBoxItem("TOTAL", 100, 1000, 100, 50),
        OCRBoxItem("350.00", 250, 1022, 100, 50),
    ]
    res4a = orchestrator.process_ocr_result(s4a_boxes)[0]
    print(res4a)
    assert res4a.totalAmount == 350.00, f"Expected total 350.00, got {res4a.totalAmount}"
    
    # Sub-case B: Small Distinct Lines (Ignore)
    print("  Sub-case B: Small Distinct Lines")
    s4b_boxes = [
        OCRBoxItem("TOTAL", 100, 1000, 100, 12),
        OCRBoxItem("8609468", 250, 1022, 100, 12),
    ]
    res4b = orchestrator.process_ocr_result(s4b_boxes)[0]
    print(res4b)
    assert res4b.totalAmount is None, f"Expected total to be None, got {res4b.totalAmount}"
    print("Scenario 4 PASSED.")

    # ----------------------------------------------------
    # Scenario 5: General Edge Cases
    # ----------------------------------------------------
    print("\nScenario 5: General Edge Cases...")
    
    # Sub-case A: Split Decimal Box
    print("  Sub-case A: Split Decimal Box")
    s5a_boxes = [
        OCRBoxItem("TOTAL", 100, 900, 100, 20),
        OCRBoxItem("123", 780, 900, 50, 20),
        OCRBoxItem(".45", 835, 900, 50, 20),
    ]
    res5a = orchestrator.process_ocr_result(s5a_boxes)[0]
    print(res5a)
    assert res5a.totalAmount is None, f"Expected total to be None, got {res5a.totalAmount}"
    assert res5a.totalRequiresVerification is True, "Expected totalRequiresVerification to be True"
    
    # Sub-case B: Comma Formatting
    print("  Sub-case B: Comma Formatting")
    s5b_boxes = [
        OCRBoxItem("TOTAL", 100, 900, 100, 20),
        OCRBoxItem("123,45", 220, 900, 80, 20),
        OCRBoxItem("LEI", 310, 900, 50, 20),
    ]
    res5b = orchestrator.process_ocr_result(s5b_boxes)[0]
    print(res5b)
    assert res5b.totalAmount == 123.45, f"Expected total 123.45, got {res5b.totalAmount}"
    
    # Sub-case C: ANAF Timeout
    print("  Sub-case C: ANAF Timeout")
    s5c_boxes = [
        OCRBoxItem("CIF:", 100, 100, 50, 20),
        OCRBoxItem("14399840", 160, 100, 100, 20),
    ]
    orchestrator_timeout = AccountingOrchestrator(simulate_timeout=True, bnr_eur_rate=5.0)
    res5c = orchestrator_timeout.process_ocr_result(s5c_boxes)[0]
    print(res5c)
    assert res5c.cui == "14399840", f"Expected CUI 14399840, got {res5c.cui}"
    assert res5c.cuiRequiresVerification is True, "Expected cuiRequiresVerification to be True under timeout simulation"
    print("Scenario 5 PASSED.")
    
    print("\n" + "=" * 60)
    print("ALL TESTS PASSED SUCCESSFULLY!")
    print("=" * 60)

if __name__ == "__main__":
    run_tests()
