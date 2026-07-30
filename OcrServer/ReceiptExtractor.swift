//
//  ReceiptExtractor.swift
//  OcrServer
//
//  Extractie completa per bon, orientata contabilitate RO.
//  Inlocuieste logica din CuiExtractorAgent + FinancialExtraction din patch-ul vechi.
//
//  Principiu anti-"aproximari": NU suprascriem niciodata in tacere o valoare
//  citita de Vision. Corectia matematica se accepta DOAR daca valoarea derivata
//  chiar apare pe bon, si intotdeauna cu warning + campul `totalSource` setat,
//  ca sa se vada in UI ce e citit si ce e derivat.
//

import Foundation

// MARK: - DTO-uri (Codable, merg direct in raspunsul JSON)

struct VatLineDTO: Codable {
    var rate: Double
    var amount: Double?
    var base: Double?
}

struct AnafInfoDTO: Codable {
    var checked: Bool = false
    var found: Bool = false
    var denumire: String?
    var adresa: String?
    var scpTVA: Bool?
    var nameScore: Double?
    var status: String = "neverificat"
}

struct AccountingEntryDTO: Codable {
    var debit: String
    var credit: String
    var amount: Double
    var label: String
}

struct ReceiptResult: Codable {
    var index: Int
    var orientation: Int = 0            // sferturi CCW fata de poza originala
    var bboxX: Double = 0
    var bboxY: Double = 0
    var bboxW: Double = 0
    var bboxH: Double = 0

    var merchantNameOCR: String?
    var cui: String?                    // doar cifre, normalizat
    var cuiOCR: String?                 // cum a fost citit
    var cuiChecksumValid: Bool = false
    var anaf: AnafInfoDTO = AnafInfoDTO()

    var buyerCui: String?
    var buyerName: String?
    var isSimplifiedInvoice: Bool = false  // CUI-ul cumparatorului e tiparit pe bon

    var bonNumber: String?
    var date: String?                   // yyyy-MM-dd
    var time: String?
    var paymentMethod: String?          // "card" / "numerar" / nil

    var total: Double?
    var totalSource: String = "lipsa"   // "ocr" | "derivat_din_tva" | "lipsa"
    var vatLines: [VatLineDTO] = []
    var mathVerified: Bool = false
    var currency: String = "RON"

    var fuelLiters: Double?
    var fuelUnitPrice: Double?
    var productHint: String?

    var suggestedAccount: String?
    var accountingNote: String?
    var vatDeductibility: String?
    var entries: [AccountingEntryDTO] = []

    var warnings: [String] = []
    var confidence: Double = 0
    var rawText: String = ""

    /// Candidati CUI reparati din OCR, rezolvati ulterior prin batch-ul ANAF.
    /// Raman in JSON — utili pentru debug.
    var anafCandidates: [String] = []
}

extension Double {
    var ron2: Double { (self * 100).rounded() / 100 }
}

// MARK: - CUI: checksum + reparare OCR + extractie cu context

enum RoCUI {

    /// Checksum oficial CUI/CIF Romania: 2–10 cifre (nu impunem minim artificial).
    /// Validarea fiscala reala se face la ANAF + potrivire denumire.
    static func isValid(_ cui: String) -> Bool {
        guard cui.count >= 2, cui.count <= 10, Int(cui) != nil else { return false }
        let key = Array("753217532".reversed())
        let digits = Array(cui.reversed())
        guard let control = digits.first?.wholeNumberValue else { return false }
        var sum = 0
        for i in 1..<digits.count where i - 1 < key.count {
            sum += (digits[i].wholeNumberValue ?? 0) * (key[i - 1].wholeNumberValue ?? 0)
        }
        var calc = (sum * 10) % 11
        if calc == 10 { calc = 0 }
        return calc == control
    }

    /// Confuzii OCR frecvente pe fonturi de imprimanta termica.
    static func repairOCRDigits(_ s: String) -> String {
        let subs: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "P": "0", "I": "1", "L": "1",
                                            "|": "1", "Z": "2", "S": "5", "B": "8", "G": "6",
                                            "@": "0"]
        return String(s.uppercased().map { subs[$0] ?? $0 })
    }

    /// Extrage CUI-ul comerciantului (universal):
    ///  1. DOAR cu context (COD FISCAL / C.I.F. / CUI / RO…) — nu orice numar
    ///  2. NICIODATA de pe linii CLIENT / CNP / BENEF (CUI cumparator)
    ///  3. CUI citit (2–10 cifre) + variante OCR → candidati
    ///  4. Rezolvarea finala: batch ANAF + fuzzy pe denumirea din antet
    static func extract(fromLines lines: [String], buyerCui: String?)
        -> (best: String?, raw: String?, checksumOK: Bool, candidates: [String]) {

        let buyerRx = try! NSRegularExpression(pattern: "CLIENT|CUMPARATOR|BENEF|CNP")
        // 2–10 cifre: CUI-ul legal poate fi scurt; OCR poate citi tokeni lungi
        let ctxRx = try! NSRegularExpression(
            pattern: "(?:COD\\s*FISC[A-Z]*|COD\\s*IDENT[A-Z]{0,8}\\s*FISC[A-Z]*|C\\.?\\s*[I1]\\.?\\s*F|\\bC\\.?\\s*F\\b|\\bCUI\\b)\\s*[.:]?\\s*(?:R(?:[O0Q]|[^A-Z0-9@]{0,3}))?\\s*[.:]?\\s*([A-Z0-9@]{2,12})|\\bR[O0]\\s?([0-9OQDILSZB@]{2,12})\\b",
            options: [.caseInsensitive])

        var raw: [String] = []
        for line in lines {
            let upper = line.uppercased()
            let range = NSRange(upper.startIndex..., in: upper)
            if buyerRx.firstMatch(in: upper, range: range) != nil { continue }
            for m in ctxRx.matches(in: upper, range: range) {
                for g in 1...2 where m.range(at: g).location != NSNotFound {
                    raw.append((upper as NSString).substring(with: m.range(at: g)))
                }
            }
        }

        // Captura poate inghiti prefixul "RO". Eliminam RO/R0; zero-uri de umplutura
        // doar daca raman cel putin 2 cifre (CUI scurt legal).
        func normalizeDigits(_ tok: String) -> String {
            var t = tok
            if t.count > 2, t.first == "R" {
                let second = t[t.index(after: t.startIndex)]
                if second == "O" || second == "0" || second == "Q" { t.removeFirst(2) }
            }
            var d = String(repairOCRDigits(t).filter { $0.isNumber })
            while d.count > 2, d.first == "0" { d.removeFirst() }
            return d
        }

        var candidates: [String] = []
        var provisionalBest: String? = nil
        var provisionalRaw: String? = raw.first
        var checksumOK = false

        for c in raw {
            let d = normalizeDigits(c)
            guard d.count >= 2, d.count <= 10 else { continue }
            if d == buyerCui { continue }

            // Mereu includem forma citita (chiar daca checksum-ul pica) — ANAF decide.
            candidates.append(d)

            if isValid(d) {
                if provisionalBest == nil {
                    provisionalBest = d
                    provisionalRaw = c
                    checksumOK = true
                }
            }

            // Variante OCR: +1/+2 cifre (trunchiere), -1 fata/spate, flip 1 cifra
            if d.count <= 9 {
                for x in "0123456789" {
                    let s1 = d + String(x)
                    if isValid(s1) { candidates.append(s1) }
                    if s1.count <= 9 {
                        for y in "0123456789" {
                            let s2 = s1 + String(y)
                            if isValid(s2) { candidates.append(s2) }
                        }
                    }
                }
            }
            if d.count > 2 {
                let dropFirst = String(d.dropFirst())
                if isValid(dropFirst) { candidates.append(dropFirst) }
                let dropLast = String(d.dropLast())
                if isValid(dropLast) { candidates.append(dropLast) }
            }
            let chars = Array(d)
            for pos in 0..<chars.count {
                for x in "0123456789" where chars[pos] != x {
                    var v = chars; v[pos] = x
                    let s = String(v)
                    if isValid(s) { candidates.append(s) }
                }
            }
        }

        var seen = Set<String>()
        candidates = candidates.filter { $0 != buyerCui && $0.count >= 2 && $0.count <= 10 && seen.insert($0).inserted }

        // Preferam forma citita de pe bon (R07745478 → 7745478), nu append-uri
        // de 1 cifra (77454781) sau flip-uri (8745478 = PF HAGIU). ANAF + nume
        // raman sursa de adevar; aici doar alegem candidatul de start bun.
        let bases = raw.map(normalizeDigits).filter { !$0.isEmpty && $0.count >= 2 && $0.count <= 10 }
        if let exact = bases.first {
            provisionalBest = exact
            checksumOK = isValid(exact)
            if !candidates.contains(exact) { candidates.insert(exact, at: 0) }
        }

        // Fallback: pe fragmente fara linia "COD FISCAL" (crop incomplet),
        // cautam CUI valid pe bon (nu CLIENT). Ex: "34626689" langa FISCAL/GPL.
        if candidates.isEmpty || provisionalBest == nil {
            let bareRx = try! NSRegularExpression(
                pattern: "\\bR[O0]?\\s*([0-9OQDILSZB]{6,10})\\b|\\b([0-9]{6,10})\\b",
                options: [.caseInsensitive])
            let skip = try! NSRegularExpression(
                pattern: "CLIENT|CNP|BENEF|CARD|TRX|POS|EJTRZ|AUTOR|TELEFON|IBAN|DATA|ORA",
                options: [.caseInsensitive])
            for line in lines {
                let upper = line.uppercased()
                let range = NSRange(upper.startIndex..., in: upper)
                if skip.firstMatch(in: upper, range: range) != nil { continue }
                // Preferam linii cu context fiscal
                let fiscalCtx = upper.range(of: "FISC|CUI|CIF|COD|SRL|S\\.A|GAZ|PETROL|MAGISTRAL|MOL|DOUGLAS",
                                            options: .regularExpression) != nil
                for m in bareRx.matches(in: upper, range: range) {
                    for g in 1...2 where m.range(at: g).location != NSNotFound {
                        let d = normalizeDigits((upper as NSString).substring(with: m.range(at: g)))
                        guard d.count >= 6, d.count <= 10, d != buyerCui else { continue }
                        // Evita sume (18075) si date
                        if d.hasPrefix("20") && d.count == 8 { continue }
                        if isValid(d) || fiscalCtx {
                            if !candidates.contains(d) { candidates.append(d) }
                            if provisionalBest == nil, isValid(d) || fiscalCtx {
                                provisionalBest = d
                                provisionalRaw = d
                                checksumOK = isValid(d)
                            }
                        }
                    }
                }
            }
        }

        // best e provizoriu (checksum); sursa de adevar = ANAF + nume dupa batch
        return (provisionalBest, provisionalRaw, checksumOK, candidates.isEmpty ? (provisionalBest.map { [$0] } ?? []) : candidates)
    }
}

// MARK: - Cote TVA Romania, in functie de data documentului (Legea 141/2025)

enum RoVAT {
    /// - de la 01.08.2025: 21% standard, 11% redusa
    /// - 9% doar tranzitoriu la locuinte pana la 31.07.2026 (nu apare pe bonuri de casa)
    /// - inainte de 01.08.2025: 19%, 9%, 5%
    static func validRates(documentDate: Date?) -> [Double] {
        guard let d = documentDate else { return [21, 11, 19, 9, 5] }
        let cal = Calendar(identifier: .gregorian)
        let switchDate = cal.date(from: DateComponents(year: 2025, month: 8, day: 1))!
        let housingEnd = cal.date(from: DateComponents(year: 2026, month: 7, day: 31))!
        if d >= switchDate { return d <= housingEnd ? [21, 11, 9] : [21, 11] }
        return [19, 9, 5]
    }

    static func warningForRate(_ rate: Double, documentDate: Date?) -> String? {
        guard let d = documentDate, !validRates(documentDate: d).contains(rate) else { return nil }
        return "Cota TVA \(Int(rate))% nu era in vigoare la data documentului — posibila eroare OCR."
    }
}

// MARK: - Sume: blacklist de context + validare/corectie matematica transparenta

enum FinExtract {

    /// Linii care NU contin sume de bani (ID-uri, autorizatii, carduri, telefoane).
    static let amountBlacklist = try! NSRegularExpression(
        pattern: "RC\\s*:|AUTOR|NR\\.?\\s*CARD|\\bTRX\\b|CNP|C\\.?I\\.?F|CUI|COD\\s+FISCAL|TELEFON|TEL\\.?\\s*[:=]|MOBIL|FAX|IBAN|CONT(?:UL)?\\s+(?:BANCAR|CURENT|RO)|BANCA|CAPITAL\\s+SOCIAL|NR\\.?\\s*(?:ORD\\.?)?\\s*REG\\.?\\s*COM|POS\\b|EJTRZ|ID\\s*UNIC|\\bSB\\s*:|AUTORIZARE|NR\\.?\\s*AUTO",
        options: [.caseInsensitive])

    /// O suma are OBLIGATORIU formatul \d{1,5}[.,]\d{2}. Un numar fara separator
    /// zecimal (4000884157, 30630040) nu e niciodata un total.
    static let amountRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\d%])(\\d{1,5})\\s?[.,]\\s?(\\d{2})(?![\\p{L}\\d])(?!\\s*%)")

    static func amounts(in line: String) -> [Double] {
        let range = NSRange(line.startIndex..., in: line)
        guard amountBlacklist.firstMatch(in: line, range: range) == nil else { return [] }
        return amountRegex.matches(in: line, range: range).compactMap { m in
            let i = (line as NSString).substring(with: m.range(at: 1))
            let f = (line as NSString).substring(with: m.range(at: 2))
            return Double("\(i).\(f)")
        }
    }

    /// Validare + corectie matematica bidirectionala, mereu TRANSPARENTA:
    /// o valoare derivata se accepta doar daca apare textual pe bon, si mereu cu warning.
    static func reconcile(total: Double?, vat: Double?, rate: Double,
                          allAmountsOnReceipt: [Double])
        -> (total: Double?, vat: Double?, verified: Bool, warning: String?, source: String) {

        func consistent(_ t: Double, _ v: Double) -> Bool {
            abs(v - t * rate / (100 + rate)) <= 0.06
        }

        if let t = total, let v = vat, consistent(t, v) {
            return (t, v, true, nil, "ocr")
        }
        if let v = vat {
            let tCalc = (v * (100 + rate) / rate).ron2
            if let match = allAmountsOnReceipt.first(where: { abs($0 - tCalc) <= 0.06 }) {
                if let t = total, abs(t - match) > 0.06 {
                    return (match, v, true,
                            "Total corectat matematic din TVA: \(t) -> \(match) (valoarea exista pe bon).",
                            "derivat_din_tva")
                }
                return (match, v, true, nil, total == nil ? "derivat_din_tva" : "ocr")
            }
            if let t = total {
                let vCalc = (t * rate / (100 + rate)).ron2
                return (t, vCalc, false,
                        "TVA recalculat din total; valoarea OCR (\(v)) nu era consistenta.", "ocr")
            }
        }
        if let t = total, vat == nil {
            let vCalc = (t * rate / (100 + rate)).ron2
            return (t, vCalc, false, "TVA calculat matematic din total (nu a fost citit).", "ocr")
        }
        return (total, vat, false, nil, total == nil ? "lipsa" : "ocr")
    }
}

// MARK: - Extractorul principal

enum ReceiptExtractor {

    static func extract(lines: [String], index: Int, buyerCuiHint: String?) -> ReceiptResult {
        var r = ReceiptResult(index: index)
        r.rawText = lines.joined(separator: "\n")
        var warnings: [String] = []

        // --- data / ora / nr. bon / plata / firma
        let (iso, docDate) = parseDate(lines)
        r.date = iso
        r.time = parseTime(lines)
        r.bonNumber = bonNumber(lines)
        r.paymentMethod = payment(lines)
        r.merchantNameOCR = merchantName(lines)

        // --- CUI comerciant + CUI cumparator
        let (bCui, bName) = buyer(lines)
        r.buyerCui = buyerCuiHint ?? bCui
        r.buyerName = bName
        r.isSimplifiedInvoice = (bCui != nil)

        let cuiRes = RoCUI.extract(fromLines: lines, buyerCui: r.buyerCui)
        r.cui = cuiRes.best
        r.cuiOCR = cuiRes.raw
        r.cuiChecksumValid = cuiRes.checksumOK
        if !cuiRes.checksumOK && !cuiRes.candidates.isEmpty {
            warnings.append("CUI citit cu erori; \(cuiRes.candidates.count) candidati trimisi la ANAF pentru rezolvare.")
        }
        r.anafCandidates = cuiRes.candidates

        // --- sume
        let allAmounts = lines.flatMap { FinExtract.amounts(in: $0) }
        let directTotal = totalAmount(lines)
        let articlesTotal = itemizedTotal(lines)
        let productTotal = productLineTotal(lines)
        // Alege totalul: prefera valoarea de pe TOTAL daca e consistenta cu TVA;
        // altfel articole / linie de produs / combustibil.
        var totalOCR = directTotal ?? articlesTotal ?? productTotal
        var totalSourceHint: String? = nil
        if directTotal == nil, articlesTotal != nil {
            totalSourceHint = "derivat_din_articole"
            warnings.append("Totalul a fost reconstruit din randurile articolelor deoarece valoarea de langa TOTAL nu a fost citita.")
        } else if directTotal == nil, productTotal != nil {
            totalSourceHint = "derivat_din_articole"
        }

        let vatRaw = vatInfo(lines, docDate: docDate)
        warnings.append(contentsOf: vatRaw.warnings)
        var vatRates = vatRaw.rates
        var vatAmounts = vatRaw.amounts

        // Daca avem TOTAL TVA dar nu cota, folosim cota legala la data documentului.
        if vatRates.isEmpty, !vatAmounts.isEmpty {
            let defaultRate = RoVAT.validRates(documentDate: docDate).first ?? 21
            vatRates = [defaultRate]
            warnings.append("Cota TVA nu a fost citita explicit; folosita cota legala \(Int(defaultRate))% la data documentului.")
        } else if vatRates.isEmpty, totalOCR != nil {
            // Bonurile fiscale RO au aproape mereu o cota; pe termice eticheta
            // "21,00 %" se pierde des. Calculam TVA din total cu cota legala.
            let defaultRate = RoVAT.validRates(documentDate: docDate).first ?? 21
            vatRates = [defaultRate]
            warnings.append("Cota TVA lipsa din OCR; TVA calculat cu cota legala \(Int(defaultRate))%.")
        }

        let mainRate = vatRates.first ?? RoVAT.validRates(documentDate: docDate).first ?? 21

        // Cand TOTAL OCR (ex. 188,75) nu bate cu TVA, dar exista o suma pe
        // linia de produs (180,75 B) sau litri x pret, o preferam.
        if let t = totalOCR, let v = vatAmounts.first {
            let expected = (v * (100 + mainRate) / mainRate).ron2
            if abs(t - expected) > 0.10 {
                if let p = productTotal, abs(p - expected) <= 0.10 {
                    totalOCR = p
                    totalSourceHint = "derivat_din_tva"
                    warnings.append("Total corectat din linia de produs: \(t) -> \(p) (consistent cu TVA).")
                } else if let match = allAmounts.first(where: { abs($0 - expected) <= 0.06 }) {
                    totalOCR = match
                    totalSourceHint = "derivat_din_tva"
                    warnings.append("Total corectat matematic din TVA: \(t) -> \(match).")
                }
            }
        }
        // Articolele castiga cand TOTAL e gol, e un procent (21,00), sau diferă
        // mult de suma articolelor (TOTAL necitit / eticheta pe alta linie).
        if let a = articlesTotal {
            let looksLikeRate = totalOCR.map { [5.0, 9.0, 11.0, 19.0, 21.0].contains($0) } ?? true
            let disagrees = totalOCR.map { abs($0 - a) > 1.0 && a > 10 } ?? false
            if totalOCR == nil || looksLikeRate || (disagrees && a > (totalOCR ?? 0)) {
                // Preferam articolele daca sunt mai mari ca un total suspect (ex. 21 vs 613)
                if looksLikeRate || totalOCR == nil || a > (totalOCR ?? 0) + 1 {
                    totalOCR = a
                    totalSourceHint = "derivat_din_articole"
                }
            }
        }

        // linii TVA (suporta cote multiple pe acelasi bon, ex. restaurant 11% + 21%)
        if vatRates.isEmpty {
            r.total = totalOCR
            r.totalSource = totalOCR == nil ? "lipsa" : (totalSourceHint ?? "ocr")
            r.mathVerified = false
            r.vatLines = []
            warnings.append("Cota TVA nu a putut fi stabilita; TVA-ul nu a fost calculat.")
        } else if vatRates.count > 1 && vatRates.count == vatAmounts.count {
            r.vatLines = zip(vatRates, vatAmounts).map { (rate, amt) in
                VatLineDTO(rate: rate, amount: amt, base: (amt * 100 / rate).ron2)
            }
            r.total = totalOCR
            r.totalSource = totalOCR == nil ? "lipsa" : (totalSourceHint ?? "ocr")
            if let total = totalOCR {
                let reconstructed = r.vatLines.reduce(0.0) {
                    $0 + ($1.base ?? 0) + ($1.amount ?? 0)
                }.ron2
                r.mathVerified = abs(total - reconstructed) <= 0.10
                if !r.mathVerified {
                    warnings.append("Totalul nu se reconciliaza cu bazele si TVA-ul cotelor multiple — verifica documentul.")
                }
            }
        } else {
            let rec = FinExtract.reconcile(total: totalOCR, vat: vatAmounts.first,
                                           rate: mainRate, allAmountsOnReceipt: allAmounts)
            r.total = rec.total
            r.totalSource = totalSourceHint ?? rec.source
            r.mathVerified = rec.verified
            if let w = rec.warning { warnings.append(w) }
            let amt = rec.vat
            let base = (r.total != nil && amt != nil) ? (r.total! - amt!).ron2 : nil
            r.vatLines = [VatLineDTO(rate: mainRate, amount: amt, base: base)]
        }
        if totalSourceHint == "derivat_din_articole", r.total != nil {
            r.totalSource = "derivat_din_articole"
        }

        // --- carburant: litri x pret unitar — poate CORECTA totalul gresit (ex. 140,20 vs 146,26)
        let f = fuel(lines)
        r.fuelLiters = f.liters
        r.fuelUnitPrice = f.price
        r.productHint = f.product
        if let l = f.liters, let p = f.price {
            let fuelTotal = (l * p).ron2
            if let t = r.total {
                if abs(fuelTotal - t) <= 0.06 {
                    r.mathVerified = true
                } else if abs(fuelTotal - t) > 0.50,
                          allAmounts.contains(where: { abs($0 - fuelTotal) <= 0.06 })
                            || abs(fuelTotal - (productTotal ?? -1)) <= 0.06 {
                    warnings.append("Total corectat din litri x pret: \(t) -> \(fuelTotal).")
                    r.total = fuelTotal
                    r.totalSource = "derivat_din_articole"
                    if let rate = r.vatLines.first?.rate {
                        let vCalc = (fuelTotal * rate / (100 + rate)).ron2
                        r.vatLines = [VatLineDTO(rate: rate, amount: vCalc,
                                                 base: (fuelTotal - vCalc).ron2)]
                        r.mathVerified = true
                    }
                } else if abs(fuelTotal - t) > 1.0 {
                    warnings.append("Litri x pret unitar (\(fuelTotal)) nu bate cu totalul (\(t)).")
                }
            } else if fuelTotal > 0 {
                r.total = fuelTotal
                r.totalSource = "derivat_din_articole"
                if let rate = r.vatLines.first?.rate ?? vatRates.first {
                    let vCalc = (fuelTotal * rate / (100 + rate)).ron2
                    r.vatLines = [VatLineDTO(rate: rate, amount: vCalc,
                                             base: (fuelTotal - vCalc).ron2)]
                    r.mathVerified = true
                }
            }
        }

        // --- incadrare contabila
        let cls = RoAccounting.classify(fullText: r.rawText)
        r.suggestedAccount = cls.account
        r.accountingNote = cls.note
        r.vatDeductibility = cls.vatDeductibility
        r.entries = RoAccounting.entries(total: r.total,
                                         vat: r.vatLines.compactMap { $0.amount }.reduce(0, +),
                                         accountCode: cls.accountCode,
                                         paymentMethod: r.paymentMethod,
                                         vatDeductibility: cls.vatDeductibility)

        // --- lipsuri obligatorii pe un bon fiscal (OUG 28/1999)
        if r.total == nil { warnings.append("Totalul nu a putut fi citit.") }
        if r.date == nil { warnings.append("Data nu a putut fi citita.") }
        if r.cui == nil && r.anafCandidates.isEmpty { warnings.append("CUI-ul comerciantului nu a fost gasit.") }

        r.warnings = warnings
        r.confidence = confidence(for: r)
        return r
    }

    // MARK: - Campuri individuale

    private static func parseDate(_ lines: [String]) -> (iso: String?, date: Date?) {
        // anul accepta si 8 in loc de 0 ("2826"), reparat mai jos
        let rx = try! NSRegularExpression(pattern: "\\b(\\d{1,2})[./-](\\d{1,2})[./-](2[08]\\d{2})\\b")
        let preferred = lines.filter { $0.uppercased().contains("DATA") } + lines

        // Print termic: 0 e citit frecvent ca 8 ("84.84.2026", "22/84/2826").
        // Cand valoarea e imposibila, incercam inlocuirea unui singur 8 cu 0.
        func repaired(_ v: Int, _ range: ClosedRange<Int>) -> Int? {
            if range.contains(v) { return v }
            let chars = Array(String(v))
            for i in chars.indices where chars[i] == "8" {
                var c = chars; c[i] = "0"
                if let r = Int(String(c)), range.contains(r) { return r }
            }
            return nil
        }

        for line in preferred {
            let r = NSRange(line.startIndex..., in: line)
            guard let m = rx.firstMatch(in: line, range: r) else { continue }
            let ns = line as NSString
            let d0 = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let mo0 = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let y0 = Int(ns.substring(with: m.range(at: 3))) ?? 0
            guard let d = repaired(d0, 1...31),
                  let mo = repaired(mo0, 1...12),
                  let y = repaired(y0, 2000...2099) else { continue }
            var comps = DateComponents()
            comps.year = y; comps.month = mo; comps.day = d
            let date = Calendar(identifier: .gregorian).date(from: comps)
            return (String(format: "%04d-%02d-%02d", y, mo, d), date)
        }
        return (nil, nil)
    }

    private static func parseTime(_ lines: [String]) -> String? {
        let rx = try! NSRegularExpression(pattern: "\\b(\\d{1,2})[:.\\-](\\d{2})(?:[:.\\-](\\d{2}))?\\b")
        for line in lines where line.uppercased().contains("ORA") {
            let r = NSRange(line.startIndex..., in: line)
            if let m = rx.firstMatch(in: line, range: r) {
                let ns = line as NSString
                let h = ns.substring(with: m.range(at: 1))
                let mi = ns.substring(with: m.range(at: 2))
                if let hv = Int(h), hv < 24 { return "\(h):\(mi)" }
            }
        }
        return nil
    }

    private static func bonNumber(_ lines: [String]) -> String? {
        let pats = ["NUMAR\\s*BON\\s*FISCAL\\s*[:#]?\\s*(\\d{1,8})",
                    "BON\\s*FISCAL\\s*[:#]?\\s*(\\d{2,8})",
                    "\\bBF\\s*[.:]?\\s*0*(\\d{1,8})"]
        for p in pats {
            let rx = try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
            for line in lines {
                let r = NSRange(line.startIndex..., in: line)
                if let m = rx.firstMatch(in: line, range: r), m.range(at: 1).location != NSNotFound {
                    return (line as NSString).substring(with: m.range(at: 1))
                }
            }
        }
        return nil
    }

    private static func payment(_ lines: [String]) -> String? {
        let t = lines.joined(separator: " ").uppercased()
        if t.range(of: "NUMERAR|CASH", options: .regularExpression) != nil { return "numerar" }
        if t.contains("CARD") { return "card" }
        return nil
    }

    private static func merchantName(_ lines: [String]) -> String? {
        let legal = try! NSRegularExpression(
            pattern: "\\b(S\\.?\\s?R\\.?\\s?L\\.?|S\\.?A\\.?|P\\.?F\\.?A\\.?|S\\.?C\\.?S\\.?|I\\.?I\\.?)(\\b|$)",
            options: [.caseInsensitive])
        let junk = try! NSRegularExpression(
            pattern: "BON\\s*FISCAL|TOTAL|TVA|CARD|CASH|NUMERAR|SUBTOTAL|DATA|ORA|CASIER|OPERATOR|POS\\b|EJTRZ|SKID|GPL\\b|MOTORINA|BENZINA",
            options: [.caseInsensitive])
        func collapse(_ s: String) -> String {
            let parts = s.split(separator: " ").map(String.init)
            var out: [String] = []
            for p in parts {
                if let last = out.last, last.caseInsensitiveCompare(p) == .orderedSame { continue }
                out.append(p)
            }
            return out.joined(separator: " ")
        }
        func isGarbage(_ s: String) -> Bool {
            let letters = s.filter { $0.isLetter }.count
            let digits = s.filter { $0.isNumber }.count
            if letters < 3 { return true }
            if digits > letters { return true }
            // "9C B 183,48 8,00 31,84 19:15:24" — coloana de sume citita ca "nume"
            if s.range(of: "\\d{1,5}[.,]\\d{2}", options: .regularExpression) != nil,
               digits >= 4 { return true }
            let r = NSRange(s.startIndex..., in: s)
            if junk.firstMatch(in: s, range: r) != nil, legal.firstMatch(in: s, range: r) == nil {
                return true
            }
            return false
        }
        // Preferam denumiri cunoscute de brand pe termice zgomotoase
        let brandRx = try! NSRegularExpression(
            pattern: "\\b(MAGISTRAL(?:\\s+GAZ)?|MOL(?:\\s+ROMANIA)?|DOUGLAS|TURIST(?:\\s+SERVICE)?|ROG(?:\\s+GAZ)?|OMV|PETROM|LIDL|KAUFLAND|CARREFOUR|MEGA\\s*IMAGE)\\b",
            options: [.caseInsensitive])
        for line in lines.prefix(12) {
            let cleaned = collapse(line.trimmingCharacters(in: .whitespaces))
            let r = NSRange(cleaned.startIndex..., in: cleaned)
            if let m = brandRx.firstMatch(in: cleaned, range: r) {
                // Extinde la SRL/SA daca e pe linie
                if legal.firstMatch(in: cleaned, range: r) != nil, !isGarbage(cleaned) {
                    return cleaned
                }
                return (cleaned as NSString).substring(with: m.range)
            }
        }
        for line in lines.prefix(10) {
            let cleaned = collapse(line.trimmingCharacters(in: .whitespaces))
            guard cleaned.count >= 6, !isGarbage(cleaned) else { continue }
            let r = NSRange(cleaned.startIndex..., in: cleaned)
            if legal.firstMatch(in: cleaned, range: r) != nil {
                return cleaned
            }
        }
        // Fallback: prima linie non-gunoi (nu sume / antet fiscal gol)
        for line in lines.prefix(6) {
            let cleaned = collapse(line.trimmingCharacters(in: .whitespaces))
            if cleaned.count >= 4, !isGarbage(cleaned) { return cleaned }
        }
        return nil
    }

    private static let rateValues: Set<Double> = [5, 9, 11, 19, 21]

    private static func totalAmount(_ lines: [String]) -> Double? {
        let rx = try! NSRegularExpression(pattern: "(?<!SUB)\\bTOTAL\\b(?!\\s*TVA)",
                                          options: [.caseInsensitive])
        let rejected = try! NSRegularExpression(
            pattern: "SUBTOTAL|TOTAL\\s*TVA|TVA\\s*TOTAL|IOTAL\\s*TVA|SUMA\\s*TVA|COTA\\s*TVA|REST|RULAJ|TOTALTVA",
            options: [.caseInsensitive])
        let inlineRx = try! NSRegularExpression(
            pattern: "(?<!SUB)\\bTOTAL\\b(?!\\s*TVA)\\s*[:=]?\\s*(\\d{1,5})\\s?[.,]\\s?(\\d{2})(?!\\s*%)",
            options: [.caseInsensitive])

        func isPlausibleTotal(_ v: Double) -> Bool {
            v >= 0.50 && v <= 99999 && !rateValues.contains(v)
        }

        for line in lines {
            let r = NSRange(line.startIndex..., in: line)
            if rejected.firstMatch(in: line, range: r) != nil { continue }
            if let m = inlineRx.firstMatch(in: line, range: r) {
                let ns = line as NSString
                if let v = Double("\(ns.substring(with: m.range(at: 1))).\(ns.substring(with: m.range(at: 2)))"),
                   isPlausibleTotal(v) { return v }
            }
        }
        for (i, line) in lines.enumerated() {
            let r = NSRange(line.startIndex..., in: line)
            if rejected.firstMatch(in: line, range: r) != nil { continue }
            guard rx.firstMatch(in: line, range: r) != nil else { continue }
            let onLine = FinExtract.amounts(in: line).filter(isPlausibleTotal)
            if let amt = onLine.max() { return amt }
            // Douglas: TOTAL pe o linie, 613.10 pe urmatoarele (uneori dupa TVA label)
            for next in lines.dropFirst(i + 1).prefix(6) {
                let nr = NSRange(next.startIndex..., in: next)
                if rejected.firstMatch(in: next, range: nr) != nil { continue }
                if next.range(of: "%|COTA\\s*TVA", options: [.regularExpression, .caseInsensitive]) != nil {
                    continue
                }
                let amts = FinExtract.amounts(in: next).filter(isPlausibleTotal)
                // Prefera sume > 30 RON (evita cote/pret unitar 4.14 pe linia gresita)
                if let amt = amts.filter({ $0 >= 30 }).max() ?? amts.max() { return amt }
            }
        }
        // Casa de marcat retipareste totalul de 2–4 ori (TOTAL/CARD/CASH).
        var freq: [String: (Double, Int)] = [:]
        for line in lines {
            let upper = line.uppercased()
            if upper.range(of: "CUI|CIF|FISCAL|COD\\s*FISC|CLIENT|CNP|RC\\s*:|AUTOR|TRX|POS\\b|EJTRZ|TELEFON|IBAN",
                           options: .regularExpression) != nil { continue }
            for v in FinExtract.amounts(in: line) where isPlausibleTotal(v) && v >= 10 {
                let key = String(format: "%.2f", v)
                let prev = freq[key]
                freq[key] = (v, (prev?.1 ?? 0) + 1)
            }
        }
        if let best = freq.values.filter({ $0.1 >= 2 }).max(by: { $0.0 < $1.0 }) {
            return best.0
        }
        return nil
    }

    /// Fallback: aduna randurile de articol cu grupa fiscala A-E (Douglas etc.).
    private static func itemizedTotal(_ lines: [String]) -> Double? {
        let full = lines.joined(separator: " ").uppercased()
        guard full.range(of: "\\bTOTAL\\b|SUBTOTAL|TOTALTVA|\\bBF\\b", options: .regularExpression) != nil
                || full.range(of: "\\b[A-E]\\b") != nil else {
            return nil
        }
        // Accepta si dubluri OCR: "443.00 A A", "72.90-A 72.90-A"
        let fiscalRow = try! NSRegularExpression(
            pattern: "(?:^|\\s|-)\\b[A-E]\\b(?:\\s+[A-E]\\b)*\\s*$", options: [.caseInsensitive])
        let fiscalInline = try! NSRegularExpression(
            pattern: "(\\d{1,5})[.,](\\d{2})\\s*-?\\s*[A-E]\\b", options: [.caseInsensitive])
        let excluded = try! NSRegularExpression(
            pattern: "\\bTOTAL\\b|SUBTOTAL|\\bTVA\\b|CARD|CASH|NUMERAR|REST|RULAJ|COTA",
            options: [.caseInsensitive])
        var values: [Double] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if excluded.firstMatch(in: line, range: range) != nil { continue }
            let upper = line.uppercased()
            let negative = upper.range(
                of: "DISCOUNT|REDUCERE|RABAT|\\d[.,]\\d{2}\\s*-\\s*[A-E]|\\d[.,]\\d{2}-[A-E]",
                options: .regularExpression) != nil
            if fiscalRow.firstMatch(in: line, range: range) != nil,
               let value = FinExtract.amounts(in: line).last,
               !rateValues.contains(value) {
                values.append(negative ? -value : value)
                continue
            }
            // "GOOD GIRL 443.00 A" cand linia nu se termina strict pe litera
            if let m = fiscalInline.firstMatch(in: line, range: range) {
                let ns = line as NSString
                if let v = Double("\(ns.substring(with: m.range(at: 1))).\(ns.substring(with: m.range(at: 2)))"),
                   !rateValues.contains(v), v >= 1 {
                    values.append(negative ? -v : v)
                }
            }
        }
        guard !values.isEmpty else { return nil }
        // Dubluri OCR pe acelasi articol: 443,443,243,243,-72.9,-72.9 → unice pe valoare+semn
        // Nu unice strict: doua articole pot avea acelasi pret. Colapsam doar perechi consecutive.
        var collapsed: [Double] = []
        for v in values {
            if let last = collapsed.last, abs(last - v) < 0.001 { continue }
            collapsed.append(v)
        }
        let total = collapsed.reduce(0, +).ron2
        return total > 0 ? total : nil
    }

    /// Linia de produs: "4,04 X44,74 LITRU 180,75 B" / "GPL 35.5 L X 4.12 146.26 G"
    private static func productLineTotal(_ lines: [String]) -> Double? {
        let rx = try! NSRegularExpression(
            pattern: "(\\d{1,5})[.,](\\d{2})\\s*[A-G]\\s*$", options: [.caseInsensitive])
        let productHint = try! NSRegularExpression(
            pattern: "LITRU|\\bL\\b|GPL|MOTORINA|BENZINA|X\\s*\\d|BUC|\\d\\s*[Xx×]",
            options: [.caseInsensitive])
        var found: [Double] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if line.uppercased().range(of: "TOTAL|TVA|CARD|REST|COTA|SUBTOTAL",
                                       options: .regularExpression) != nil { continue }
            guard productHint.firstMatch(in: line, range: range) != nil
                    || rx.firstMatch(in: line, range: range) != nil,
                  let m = rx.firstMatch(in: line, range: range) else { continue }
            let ns = line as NSString
            if let v = Double("\(ns.substring(with: m.range(at: 1))).\(ns.substring(with: m.range(at: 2)))"),
               !rateValues.contains(v), v >= 1 {
                found.append(v)
            }
        }
        return found.max()
    }

    private static func vatInfo(_ lines: [String], docDate: Date?)
        -> (rates: [Double], amounts: [Double], warnings: [String]) {
        var rates: [Double] = []
        var amounts: [Double] = []
        var warnings: [String] = []
        let rateRx = try! NSRegularExpression(
            pattern: "(?:COTA\\s*)?(?:TOTAL\\s*)?TVA\\s*[A-E]?\\s*[=:]?\\s*(\\d{1,2})(?:[.,]\\d{1,2})?\\s*[%X×x]",
            options: [.caseInsensitive])
        let rateBareRx = try! NSRegularExpression(
            pattern: "\\b(\\d{1,2})[.,]00\\s*%", options: [.caseInsensitive])
        let tvaAmountRx = try! NSRegularExpression(
            pattern: "TOTAL\\s*TVA|TVA\\s*TOTAL|IOTAL\\s*TVA|TOTALTVA|SUMA\\s*TVA",
            options: [.caseInsensitive])
        var pairs: [(rate: Double, amount: Double)] = []
        for line in lines {
            let r = NSRange(line.startIndex..., in: line)
            let ns = line as NSString
            var lineRates = rateRx.matches(in: line, range: r).compactMap { m -> Double? in
                Double(ns.substring(with: m.range(at: 1)))
            }.filter { $0 > 0 && $0 < 100 }
            if lineRates.isEmpty {
                lineRates = rateBareRx.matches(in: line, range: r).compactMap { m -> Double? in
                    Double(ns.substring(with: m.range(at: 1)))
                }.filter { rateValues.contains($0) }
            }
            let lineAmounts = FinExtract.amountRegex.matches(in: line, range: r).compactMap { m -> Double? in
                let whole = ns.substring(with: m.range(at: 1))
                let fraction = ns.substring(with: m.range(at: 2))
                return Double("\(whole).\(fraction)")
            }.filter { !rateValues.contains($0) }
            for v in lineRates {
                if !rates.contains(v) {
                    rates.append(v)
                    if let w = RoVAT.warningForRate(v, documentDate: docDate) { warnings.append(w) }
                }
            }
            if lineRates.count >= 1, lineAmounts.count >= 1 {
                if lineRates.count == lineAmounts.count {
                    for (v, amt) in zip(lineRates, lineAmounts)
                        where !pairs.contains(where: { $0.rate == v }) {
                        pairs.append((v, amt))
                    }
                } else if lineRates.count == 1, let v = lineRates.first, let amt = lineAmounts.last,
                          !pairs.contains(where: { $0.rate == v }) {
                    pairs.append((v, amt))
                }
            }
            if tvaAmountRx.firstMatch(in: line, range: r) != nil {
                for m in FinExtract.amountRegex.matches(in: line, range: r) {
                    let i = ns.substring(with: m.range(at: 1))
                    let f = ns.substring(with: m.range(at: 2))
                    if let v = Double("\(i).\(f)"), !rateValues.contains(v), !amounts.contains(v) {
                        amounts.append(v)
                    }
                }
            }
        }
        if pairs.count >= 2 {
            return (pairs.map { $0.rate }, pairs.map { $0.amount }, warnings)
        }
        if pairs.count == 1, amounts.isEmpty {
            amounts = [pairs[0].amount]
            if rates.isEmpty { rates = [pairs[0].rate] }
        }
        return (rates, amounts, warnings)
    }

    private static func buyer(_ lines: [String]) -> (cui: String?, name: String?) {
        var cui: String? = nil
        var name: String? = nil
        let cuiRx = try! NSRegularExpression(
            pattern: "(?:CIF\\s*/?\\s*CNP\\s*CLIENT|C\\.?I\\.?F\\.?\\s*CLIENT|CUI\\s*CLIENT|COD\\s*CLIENT)\\s*[.:]?\\s*(?:R[O0])?\\s*([0-9OQDILSZB]{4,10})",
            options: [.caseInsensitive])
        let nameRx = try! NSRegularExpression(
            pattern: "\\bCLIENT\\s*[.:]\\s*([A-Z][A-Z0-9 .\\-]{3,40})",
            options: [.caseInsensitive])
        for line in lines {
            let r = NSRange(line.startIndex..., in: line)
            if cui == nil, let m = cuiRx.firstMatch(in: line, range: r),
               m.range(at: 1).location != NSNotFound {
                let d = String(RoCUI.repairOCRDigits((line as NSString).substring(with: m.range(at: 1)))
                    .filter { $0.isNumber })
                if d.count >= 4 { cui = d }
            }
            if name == nil, !line.uppercased().contains("CIF"), !line.uppercased().contains("CNP"),
               let m = nameRx.firstMatch(in: line, range: r), m.range(at: 1).location != NSNotFound {
                let candidate = (line as NSString).substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
                if candidate.rangeOfCharacter(from: .letters) != nil { name = candidate }
            }
        }
        return (cui, name)
    }

    private static func fuel(_ lines: [String]) -> (liters: Double?, price: Double?, product: String?) {
        var product: String? = nil
        let prodRx = try! NSRegularExpression(pattern: "MOTORINA[A-Z0-9 ]*|BENZINA[A-Z0-9 ]*|\\bGPL\\b|DIESEL|ADBLUE",
                                              options: [.caseInsensitive])
        for line in lines {
            let r = NSRange(line.startIndex..., in: line)
            if let m = prodRx.firstMatch(in: line, range: r) {
                product = (line as NSString).substring(with: m.range)
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // DOAR pe linii de carburant. Altfel "443.00 x 243.00" de pe Douglas
        // (preturi de articole) era interpretat ca litri×pret → total 107649.
        // Formate: "10,39 X18,11 L", "4,14 X44,32 LITRU", "35,5 L X 4,12"
        let pairRx = try! NSRegularExpression(
            pattern: "(\\d{1,3}[.,]\\d{1,3})\\s*(?:L(?:ITRU)?\\s*)?[Xx×]\\s*(\\d{1,3}[.,]\\d{1,3})\\s*L?(?:ITRU)?")
        for line in lines {
            let up = line.uppercased()
            let r = NSRange(up.startIndex..., in: up)
            let isFuelLine = product != nil
                || up.range(of: "\\bL(?:ITRU)?\\b|MOTORINA|BENZINA|\\bGPL\\b|DIESEL|ADBLUE",
                            options: .regularExpression) != nil
            guard isFuelLine, let m = pairRx.firstMatch(in: up, range: r) else { continue }
            let ns = up as NSString
            func num(_ i: Int) -> Double? {
                Double(ns.substring(with: m.range(at: i)).replacingOccurrences(of: ",", with: "."))
            }
            guard let a = num(1), let b = num(2) else { continue }
            // pret pompa tipic 2.5–25 RON/L; litri tipic 1–200 (nu sute de lei ca pret produs)
            let priceRange = 2.0...25.0
            let litersRange = 0.5...250.0
            let (liters, price): (Double, Double)
            if priceRange.contains(a) && litersRange.contains(b) && !priceRange.contains(b) {
                (liters, price) = (b, a)
            } else if priceRange.contains(b) && litersRange.contains(a) && !priceRange.contains(a) {
                (liters, price) = (a, b)
            } else if priceRange.contains(a) && litersRange.contains(b) {
                (liters, price) = (b, a)
            } else if priceRange.contains(b) && litersRange.contains(a) {
                (liters, price) = (a, b)
            } else {
                continue  // doua preturi de magazin (443 x 243) — NU e carburant
            }
            // sanity: litri×pret nu depaseste un total rezonabil de bon
            if liters * price > 50_000 { continue }
            return (liters, price, product)
        }
        return (nil, nil, product)
    }

    private static func confidence(for r: ReceiptResult) -> Double {
        var c = 0.35
        if r.cuiChecksumValid { c += 0.15 }
        if r.mathVerified { c += 0.20 }
        if r.date != nil { c += 0.10 }
        if r.total != nil { c += 0.10 }
        if r.bonNumber != nil { c += 0.05 }
        if r.anaf.status == "confirmat_anaf" || r.anaf.status == "confirmat_anaf_reparat" { c += 0.05 }
        c -= Double(r.warnings.count) * 0.04
        return min(1, max(0, c)).ron2
    }
}
