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

    /// Checksum-ul oficial. MIN 4 cifre — sub 4, checksum-ul valideaza si "25", "21" etc.
    static func isValid(_ cui: String) -> Bool {
        guard cui.count >= 4, cui.count <= 10, Int(cui) != nil else { return false }
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
        let subs: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1",
                                            "|": "1", "Z": "2", "S": "5", "B": "8", "G": "6",
                                            "@": "0"]
        return String(s.uppercased().map { subs[$0] ?? $0 })
    }

    /// Extrage CUI-ul comerciantului:
    ///  - DOAR cu context (COD FISCAL / C.I.F. / CUI / prefix RO)
    ///  - NICIODATA de pe linii CLIENT / CNP / BENEF (acolo e CUI-ul cumparatorului)
    ///  - daca checksum-ul nu trece, genereaza candidati cu o cifra reparata/adaugata;
    ///    candidatii se rezolva ulterior prin batch-ul ANAF + fuzzy match pe denumire.
    static func extract(fromLines lines: [String], buyerCui: String?)
        -> (best: String?, raw: String?, checksumOK: Bool, candidates: [String]) {

        let buyerRx = try! NSRegularExpression(pattern: "CLIENT|CUMPARATOR|BENEF|CNP")
        let ctxRx = try! NSRegularExpression(
            pattern: "(?:COD\\s*FISCAL|COD\\s*IDENTIFICARE\\s*FISCALA|C\\.?\\s*[I1]\\.?\\s*F|\\bCUI\\b)\\s*[.:]?\\s*(?:R[O0Q])?\\s*[.:]?\\s*([A-Z0-9@]{4,10})|\\bR[O0]\\s?([0-9OQDILSZB@]{4,10})\\b",
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

        // 1) checksum direct
        for c in raw {
            let d = String(repairOCRDigits(c).filter { $0.isNumber })
            if isValid(d), d != buyerCui { return (d, c, true, [d]) }
        }

        // 2) reparare ghidata de checksum -> candidati pentru batch-ul ANAF
        var candidates: [String] = []
        for c in raw {
            let d = String(repairOCRDigits(c).filter { $0.isNumber })
            guard d.count >= 4 else { continue }
            for x in "0123456789" where isValid(d + String(x)) { candidates.append(d + String(x)) }
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
        candidates = candidates.filter { $0 != buyerCui && seen.insert($0).inserted }
        return (nil, raw.first, false, candidates)
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
        pattern: "RC\\s*:|AUTOR|NR\\.?\\s*CARD|\\bTRX\\b|CNP|C\\.?I\\.?F|TELEFON|POS\\b|EJTRZ|ID\\s*UNIC|\\bSB\\s*:|AUTORIZARE|NR\\.?\\s*AUTO",
        options: [.caseInsensitive])

    /// O suma are OBLIGATORIU formatul \d{1,5}[.,]\d{2}. Un numar fara separator
    /// zecimal (4000884157, 30630040) nu e niciodata un total.
    static let amountRegex = try! NSRegularExpression(
        pattern: "(?<![\\d%])(\\d{1,5})\\s?[.,]\\s?(\\d{2})(?!\\d)")

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
        let totalOCR = totalAmount(lines)
        let vat = vatInfo(lines, docDate: docDate)
        warnings.append(contentsOf: vat.warnings)
        let mainRate = vat.rates.first ?? RoVAT.validRates(documentDate: docDate).first ?? 21

        let rec = FinExtract.reconcile(total: totalOCR, vat: vat.amounts.first,
                                       rate: mainRate, allAmountsOnReceipt: allAmounts)
        r.total = rec.total
        r.totalSource = rec.source
        r.mathVerified = rec.verified
        if let w = rec.warning { warnings.append(w) }

        // linii TVA (suporta cote multiple pe acelasi bon, ex. restaurant 11% + 21%)
        if vat.rates.count > 1 && vat.rates.count == vat.amounts.count {
            r.vatLines = zip(vat.rates, vat.amounts).map { (rate, amt) in
                VatLineDTO(rate: rate, amount: amt, base: nil)
            }
        } else {
            let amt = rec.vat
            let base = (r.total != nil && amt != nil) ? (r.total! - amt!).ron2 : nil
            r.vatLines = [VatLineDTO(rate: mainRate, amount: amt, base: base)]
        }

        // --- carburant: litri x pret unitar, cross-check cu totalul
        let f = fuel(lines)
        r.fuelLiters = f.liters
        r.fuelUnitPrice = f.price
        r.productHint = f.product
        if let l = f.liters, let p = f.price, let t = r.total {
            if abs(l * p - t) <= 0.06 {
                r.mathVerified = true
            } else if abs(l * p - t) > 1.0 {
                warnings.append("Litri x pret unitar (\((l * p).ron2)) nu bate cu totalul (\(t)).")
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
        let rx = try! NSRegularExpression(pattern: "\\b(\\d{1,2})[./-](\\d{1,2})[./-](20\\d{2})\\b")
        let preferred = lines.filter { $0.uppercased().contains("DATA") } + lines
        for line in preferred {
            let r = NSRange(line.startIndex..., in: line)
            guard let m = rx.firstMatch(in: line, range: r) else { continue }
            let ns = line as NSString
            let d = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let mo = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let y = Int(ns.substring(with: m.range(at: 3))) ?? 0
            guard (1...31).contains(d), (1...12).contains(mo) else { continue }
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
        for line in lines.prefix(6) {
            let r = NSRange(line.startIndex..., in: line)
            if legal.firstMatch(in: line, range: r) != nil, line.count >= 6 {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return lines.first?.trimmingCharacters(in: .whitespaces)
    }

    private static func totalAmount(_ lines: [String]) -> Double? {
        let rx = try! NSRegularExpression(pattern: "(?<!SUB)\\bTOTAL\\b(?!\\s*TVA)",
                                          options: [.caseInsensitive])
        for (i, line) in lines.enumerated() {
            let r = NSRange(line.startIndex..., in: line)
            guard rx.firstMatch(in: line, range: r) != nil else { continue }
            if let amt = FinExtract.amounts(in: line).first { return amt }
            // eticheta si suma pot pica pe linii OCR diferite
            for next in lines.dropFirst(i + 1).prefix(2) {
                if let amt = FinExtract.amounts(in: next).first { return amt }
            }
        }
        return nil
    }

    private static func vatInfo(_ lines: [String], docDate: Date?)
        -> (rates: [Double], amounts: [Double], warnings: [String]) {
        var rates: [Double] = []
        var amounts: [Double] = []
        var warnings: [String] = []
        let rateRx = try! NSRegularExpression(
            pattern: "(?:COTA\\s*)?TVA\\s*[A-E]?\\s*[=:]?\\s*(\\d{1,2})(?:[.,]\\d{1,2})?\\s*%",
            options: [.caseInsensitive])
        let tvaAmountRx = try! NSRegularExpression(pattern: "TOTAL\\s*TVA", options: [.caseInsensitive])
        for line in lines {
            let r = NSRange(line.startIndex..., in: line)
            for m in rateRx.matches(in: line, range: r) {
                if let v = Double((line as NSString).substring(with: m.range(at: 1))),
                   v > 0, v < 100, !rates.contains(v) {
                    rates.append(v)
                    if let w = RoVAT.warningForRate(v, documentDate: docDate) { warnings.append(w) }
                }
            }
            if tvaAmountRx.firstMatch(in: line, range: r) != nil {
                // blacklist-ul nu se aplica aici: linia e explicit "TOTAL TVA"
                let ns = line as NSString
                for m in FinExtract.amountRegex.matches(in: line, range: r) {
                    let i = ns.substring(with: m.range(at: 1))
                    let f = ns.substring(with: m.range(at: 2))
                    if let v = Double("\(i).\(f)"), !amounts.contains(v) { amounts.append(v) }
                }
            }
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
        // formate reale: "10,39 X18,11 L", "4,14 X44,32 LITRU", "35,5 L X 4,12", "4,20 X43,131 LITRU"
        let pairRx = try! NSRegularExpression(
            pattern: "(\\d{1,3}[.,]\\d{1,3})\\s*(?:L(?:ITRU)?\\s*)?[Xx×]\\s*(\\d{1,3}[.,]\\d{1,3})")
        for line in lines {
            let up = line.uppercased()
            let r = NSRange(up.startIndex..., in: up)
            guard let m = pairRx.firstMatch(in: up, range: r) else { continue }
            let ns = up as NSString
            func num(_ i: Int) -> Double? {
                Double(ns.substring(with: m.range(at: i)).replacingOccurrences(of: ",", with: "."))
            }
            guard let a = num(1), let b = num(2) else { continue }
            // pretul unitar la pompa e in mod normal 2.5-15 RON; litrii, de regula, mai multi
            let (liters, price): (Double, Double)
            if (2.5...15).contains(a) && !(2.5...15).contains(b) { (liters, price) = (b, a) }
            else if (2.5...15).contains(b) && !(2.5...15).contains(a) { (liters, price) = (a, b) }
            else { (liters, price) = (max(a, b), min(a, b)) }
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


