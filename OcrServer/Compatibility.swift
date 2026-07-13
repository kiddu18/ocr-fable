//
//  Compatibility.swift
//  OcrServer
//
//  Tipuri de compatibilitate pentru agentii vechi din VaporServer.swift care se folosesc pe PDF-uri.
//

import Foundation

enum CUI {
    /// MIN 4 CIFRE (nu 2!) — cu 2 cifre checksum-ul validează "25", "19", "21" etc.
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

    /// Reparare de cifre pt. confuzii OCR frecvente (O→0, I→1, S→5, B→8, @→0 ...)
    static func repairOCRDigits(_ s: String) -> String {
        let subs: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1",
                                            "|": "1", "Z": "2", "S": "5", "B": "8", "G": "6", "@": "0"]
        return String(s.uppercased().map { subs[$0] ?? $0 })
    }

    /// Extrage candidații CUI dintr-un bon:
    static func candidates(fromLines lines: [String], buyerCui: String?) -> (best: String?, verified: Bool, anafCandidates: [String]) {
        let normalizedBuyerCui = buyerCui.map { repairOCRDigits($0).filter { $0.isNumber } }
        let buyerRegex = try! NSRegularExpression(pattern: "CLIENT|CUMPARATOR|BENEF|CNP")
        let ctxRegex = try! NSRegularExpression(
            pattern: "(?:COD\\s*FISCAL|COD\\s*IDENTIFICARE\\s*FISCALA|C\\.?\\s*[I1]\\.?\\s*F|CUI)\\s*[.:]?\\s*(?:R[O0Q])?\\s*[.:]?\\s*([A-Z0-9@]{4,10})|\\bR[O0]\\s?([0-9OQDILSZB@]{4,10})\\b",
            options: [.caseInsensitive])

        var raw: [String] = []
        for line in lines {
            let upper = line.uppercased()
            let range = NSRange(upper.startIndex..., in: upper)
            if buyerRegex.firstMatch(in: upper, range: range) != nil { continue }
            for m in ctxRegex.matches(in: upper, range: range) {
                for g in 1...2 where m.range(at: g).location != NSNotFound {
                    raw.append((upper as NSString).substring(with: m.range(at: g)))
                }
            }
        }

        // 1) match direct pe checksum
        for c in raw {
            let d = repairOCRDigits(c).filter { $0.isNumber }
            if isValid(d), d != normalizedBuyerCui { return (d, true, [d]) }
        }
        // 2) reparare ghidată de checksum → candidați pentru batch-ul ANAF
        var anafCandidates: [String] = []
        for c in raw {
            let d = repairOCRDigits(c).filter { $0.isNumber }
            guard d.count >= 4 else { continue }
            for x in "0123456789" where isValid(d + String(x)) { anafCandidates.append(d + String(x)) }
            let chars = Array(d)
            for pos in 0..<chars.count {
                for x in "0123456789" where chars[pos] != x {
                    var v = chars; v[pos] = x
                    let s = String(v)
                    if isValid(s) { anafCandidates.append(s) }
                }
            }
        }
        var seen = Set<String>()
        anafCandidates = anafCandidates.filter { $0 != normalizedBuyerCui && seen.insert($0).inserted }
        return (anafCandidates.first, false, anafCandidates)
    }
}

struct ANAFCompany {
    let cui: String
    let denumire: String?
    let adresa: String?
    let scpTVA: Bool?
}

enum ANAF {
    static let endpoint = URL(string: "https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva")!

    static func verifyBatch(cuis: [String]) async -> [String: ANAFCompany] {
        guard !cuis.isEmpty else { return [:] }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let payload = cuis.prefix(100).map { ["cui": $0, "data": today] }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return [:] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = json["found"] as? [[String: Any]] else { return [:] }

        var out: [String: ANAFCompany] = [:]
        for f in found {
            let dg = f["date_generale"] as? [String: Any] ?? [:]
            let cuiInt = (dg["cui"] as? Int) ?? (dg["cui"] as? String).flatMap(Int.init) ?? 0
            let cuiStr = String(cuiInt)
            guard cuiInt > 0 else { continue }
            let tva = (f["inregistrare_scop_Tva"] as? [String: Any])?["scpTVA"] as? Bool
            out[cuiStr] = ANAFCompany(cui: cuiStr, denumire: dg["denumire"] as? String,
                                     adresa: dg["adresa"] as? String, scpTVA: tva)
        }
        return out
    }

    static func nameMatchScore(anafName: String, ocrHeader: String) -> Double {
        func tokens(_ s: String) -> Set<String> {
            Set(s.uppercased()
                 .replacingOccurrences(of: "[^A-Z0-9 ]", with: " ", options: .regularExpression)
                 .split(separator: " ")
                 .map(String.init)
                 .filter { $0.count > 2 && !["SRL", "THE"].contains($0) })
        }
        let a = tokens(anafName), b = tokens(ocrHeader)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}

enum RomanianVAT {
    static func validRates(documentDate: Date?) -> [Double] {
        guard let d = documentDate else { return [21, 11, 19, 9, 5] }
        let cal = Calendar(identifier: .gregorian)
        let switchDate = cal.date(from: DateComponents(year: 2025, month: 8, day: 1))!
        let housingEnd = cal.date(from: DateComponents(year: 2026, month: 7, day: 31))!
        if d >= switchDate {
            return d <= housingEnd ? [21, 11, 9] : [21, 11]
        }
        return [19, 9, 5]
    }

    static func warningForRate(_ rate: Double, documentDate: Date?) -> String? {
        guard let d = documentDate, !validRates(documentDate: d).contains(rate) else { return nil }
        return "Cota TVA \(Int(rate))% nu era în vigoare la data documentului — posibilă eroare OCR."
    }
}

enum FinancialExtraction {
    static let amountBlacklist = try! NSRegularExpression(
        pattern: "RC\\s*:|AUTOR|NR\\.?\\s*CARD|TRX|CNP|C\\.?I\\.?F|TELEFON|POS\\b|EJTRZ|ID\\s*UNIC",
        options: [.caseInsensitive])

    static let amountRegex = try! NSRegularExpression(pattern: "(?<![\\d%])(\\d{1,5})\\s?[.,]\\s?(\\d{2})(?!\\d)")

    static func amounts(in line: String) -> [Double] {
        let range = NSRange(line.startIndex..., in: line)
        guard amountBlacklist.firstMatch(in: line, range: range) == nil else { return [] }
        return amountRegex.matches(in: line, range: range).compactMap { m in
            let i = (line as NSString).substring(with: m.range(at: 1))
            let f = (line as NSString).substring(with: m.range(at: 2))
            return Double("\(i).\(f)")
        }
    }

    static func isVatRateLike(_ value: Double) -> Bool {
        [21.0, 19.0, 11.0, 9.0, 5.0].contains(value)
    }

    static func isTotalLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        if upper.range(of: "\\b(SUBTOTAL|TOTAL\\s+TVA|TVA\\s+TOTAL|TOTAL\\s+TAXA|TOTAL\\s+TAXE|REST)\\b", options: .regularExpression) != nil {
            return false
        }
        return upper.range(of: "\\b(TOTAL|T0TAL|TIAL|TLAL|SUMA|ACHITAT|PLATA)\\b", options: .regularExpression) != nil
    }

    static func isUnitOrQuantityLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.range(
            of: "\\b(L|LITRI|LITRU|LITR|GPL|BENZINA|MOTORINA|PRET|PRICE|PU)\\b|\\bX\\s*[0-9]+[.,][0-9]{2}\\b",
            options: .regularExpression
        ) != nil
    }

    static func totalCandidates(in line: String) -> [Double] {
        let values = amounts(in: line).filter { !isVatRateLike($0) && $0 > 0 }
        if isTotalLine(line) { return values }
        if isUnitOrQuantityLine(line) { return [] }
        return []
    }

    static func isVatSummaryLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        if upper.range(of: "\\b(CUI|CIF|COD\\s+FISCAL|CARD|TRX|AUTOR|CLIENT)\\b", options: .regularExpression) != nil {
            return false
        }
        return upper.range(of: "\\b(TVA|COTA|TAXA)\\b", options: .regularExpression) != nil
            || upper.range(of: "\\b[0-9]{1,2}(?:[.,][0-9]{1,2})?\\s*%", options: .regularExpression) != nil
    }

    static func vatSummaryAmounts(in line: String) -> [Double] {
        guard isVatSummaryLine(line) else { return [] }
        return amounts(in: line).filter { !isVatRateLike($0) && $0 > 0 }
    }

    static func reconcile(total: Double?, vat: Double?, rate: Double,
                          allAmountsOnReceipt: [Double]) -> (total: Double?, vat: Double?, verified: Bool, warning: String?) {
        func consistent(_ t: Double, _ v: Double) -> Bool { abs(v - t * rate / (100 + rate)) <= 0.06 }

        if let t = total, let v = vat, consistent(t, v) { return (t, v, true, nil) }

        if let v = vat {
            let tCalc = (v * (100 + rate) / rate * 100).rounded() / 100
            if let match = allAmountsOnReceipt.first(where: { abs($0 - tCalc) <= 0.06 }) {
                let warn = (total != nil && abs(total! - match) > 0.06)
                    ? "Total corectat matematic din TVA: \(total!) → \(match)" : nil
                return (match, v, true, warn)
            }
            if let t = total {
                let vCalc = (t * rate / (100 + rate) * 100).rounded() / 100
                return (t, vCalc, false, "TVA recalculat din total (valoarea OCR nu era consistentă)")
            }
        }
        if let t = total, vat == nil {
            let vCalc = (t * rate / (100 + rate) * 100).rounded() / 100
            return (t, vCalc, false, "TVA calculat matematic din total")
        }
        return (total, vat, false, nil)
    }
}

enum AccountSuggestion {
    static func suggest(fullText: String) -> (account: String, note: String?) {
        let t = fullText.uppercased()
        if t.range(of: "MOTORINA|BENZINA|GPL|DIESEL|OMV|PETROM|\\bMOL\\b|ROMPETROL|GAZ SRL",
                   options: .regularExpression) != nil {
            return ("6022",
                    "TVA deductibilă 50% dacă vehiculul nu este utilizat exclusiv în scop economic (art. 298 CF); 100% cu foaie de parcurs.")
        }
        if t.range(of: "PARFUMERIE|DOUGLAS|SEPHORA|CADOU", options: .regularExpression) != nil {
            return ("623", "Protocol: deductibilitate limitată la impozitul pe profit.")
        }
        if t.range(of: "RESTAURANT|CATERING|CAFENEA|PIZZA", options: .regularExpression) != nil {
            return ("623", "Atenție: pe același bon mâncarea e la 11%, alcoolul la 21%.")
        }
        if t.range(of: "PAPETARIE|BIROTICA|EMAG|ALTEX", options: .regularExpression) != nil {
            return ("604", nil)
        }
        return ("628", "Necesită încadrare manuală.")
    }
}
