//
//  AnafValidator.swift
//  OcrServer
//
//  Dubla validare CUI + denumire cu ANAF (serviciul public PlatitorTvaRest v9).
//
//  Detalii v9 (difera de v8!):
//   - URL: https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva
//   - limita: max 100 CUI-uri per request, 1 request / secunda
//     => UN SINGUR batch pentru toata poza, niciodata per bon!
//   - JSON restructurat: raspunsul nu mai are "cod"/"message" ca v8,
//     iar "date_generale.cui" vine ca NUMAR (fara ghilimele), nu ca string.
//

import Foundation

struct AnafCompany {
    let cui: String
    let denumire: String?
    let adresa: String?
    let scpTVA: Bool?
    let statusInactiv: Bool?
}

actor AnafClient {

    static let shared = AnafClient()

    private let endpoint = URL(string: "https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva")!
    private var cache: [String: AnafCompany] = [:]
    private var notFoundCache: Set<String> = []
    private var lastRequest = Date.distantPast

    /// Verifica toate CUI-urile intr-un singur apel (chunk-uri de 100 daca e nevoie).
    func verifyBatch(_ cuis: [String]) async -> [String: AnafCompany] {
        let unique = Array(Set(cuis.filter { !$0.isEmpty && Int($0) != nil }))
        var result: [String: AnafCompany] = [:]
        var toQuery: [String] = []
        for c in unique {
            if let hit = cache[c] { result[c] = hit }
            else if !notFoundCache.contains(c) { toQuery.append(c) }
        }
        guard !toQuery.isEmpty else { return result }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let today = df.string(from: Date())

        var index = 0
        while index < toQuery.count {
            let chunk = Array(toQuery[index..<min(index + 100, toQuery.count)])
            index += 100

            // rate limit ANAF: 1 request / secunda
            let wait = 1.1 - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            lastRequest = Date()

            let payload: [[String: Any]] = chunk.compactMap { c in
                Int(c).map { ["cui": $0, "data": today] }
            }
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { continue }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 12

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = json["found"] as? [[String: Any]] else { continue }

            var foundSet = Set<String>()
            for f in found {
                let dg = f["date_generale"] as? [String: Any] ?? [:]
                // v9: "cui" vine ca numar, nu ca string
                let cui = (dg["cui"] as? Int).map(String.init)
                    ?? (dg["cui"] as? String)
                    ?? ""
                guard !cui.isEmpty else { continue }
                let comp = AnafCompany(
                    cui: cui,
                    denumire: dg["denumire"] as? String,
                    adresa: dg["adresa"] as? String,
                    scpTVA: (f["inregistrare_scop_Tva"] as? [String: Any])?["scpTVA"] as? Bool,
                    statusInactiv: dg["statusInactivi"] as? Bool)
                cache[cui] = comp
                result[cui] = comp
                foundSet.insert(cui)
            }
            for c in chunk where !foundSet.contains(c) { notFoundCache.insert(c) }
        }
        return result
    }

    /// Similaritate pe tokenuri intre denumirea oficiala ANAF si antetul OCR.
    nonisolated static func nameMatchScore(anafName: String, ocrHeader: String) -> Double {
        func tokens(_ s: String) -> Set<String> {
            let stop: Set<String> = ["SRL", "SA", "SRL", "THE", "COM", "PROD", "IMPEX", "GROUP", "AND"]
            // Colapseaza spatii OCR: "MO L" → incearca si "MOL" prin n-gram pe litere
            let cleaned = s.uppercased()
                .replacingOccurrences(of: "[^A-Z0-9 ]", with: " ", options: .regularExpression)
            var out = Set(cleaned.split(separator: " ").map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) })
            // Concateneaza tokeni scurti vecini ("MO"+"L" → nu, dar litere lipite ajuta)
            let letters = cleaned.replacingOccurrences(of: " ", with: "")
            if letters.count >= 4 {
                // Adauga prefixe brand frecvente din antet (primele 6–12 litere)
                for len in [4, 5, 6, 7, 8] where letters.count >= len {
                    out.insert(String(letters.prefix(len)))
                }
            }
            return out
        }
        let a = tokens(anafName), b = tokens(ocrHeader)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let base = Double(inter) / Double(min(a.count, b.count))
        // Bonus daca un token lung din ANAF e substring in antet (MOL in MOLROMANIA...)
        let aStr = anafName.uppercased()
        let bStr = ocrHeader.uppercased().replacingOccurrences(of: " ", with: "")
        var bonus = 0.0
        for t in a where t.count >= 4 && bStr.contains(t) { bonus += 0.15 }
        for t in b where t.count >= 4 && aStr.replacingOccurrences(of: " ", with: "").contains(t) {
            bonus += 0.10
        }
        return min(1.0, base + bonus)
    }
}

// MARK: - Rezolvarea candidatilor per bon

enum AnafResolver {

    /// Alege CUI-ul final dintre candidati:
    ///  1. interogare ANAF (deja facuta in batch)
    ///  2. potrivire denumire oficiala ↔ antet OCR (merchant name)
    /// Checksum-ul local e doar un indiciu; ANAF + nume decid.
    /// `checksumWasValid` = forma citita de pe bon trece checksum-ul (2–10 cifre).
    static func resolve(candidates: [String], checksumWasValid: Bool,
                        ocrHeader: String, anaf: [String: AnafCompany])
        -> (cui: String?, company: AnafCompany?, score: Double, status: String) {

        let found = candidates.compactMap { cui -> (String, AnafCompany)? in
            anaf[cui].map { (cui, $0) }
        }

        // Un singur hit ANAF → acceptam (indiferent de checksum), denumirea oficiala e adevarul.
        if found.count == 1 {
            let (cui, company) = found[0]
            let score = AnafClient.nameMatchScore(
                anafName: company.denumire ?? "", ocrHeader: ocrHeader)
            let repaired = !checksumWasValid || (candidates.first != cui)
            return (cui, company, score,
                    repaired ? "confirmat_anaf_reparat" : "confirmat_anaf")
        }

        // Mai multi candidati gasiti la ANAF: castiga cel cu denumirea cea mai apropiata
        // de antetul bonului (ex. "MOL ROMANIA..." vs candidati trunchiati / flip PF HAGIU).
        let ocrForm = candidates.first ?? ""
        func digitDistance(_ a: String, _ b: String) -> Int {
            // Distanta pe sufix/prefix: prefera CUI-ul cel mai apropiat de forma citita.
            if a == b { return 0 }
            if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
            if a.hasPrefix(b) || b.hasPrefix(a) { return abs(a.count - b.count) }
            var n = 0
            let aa = Array(a), bb = Array(b)
            let m = min(aa.count, bb.count)
            for i in 0..<m where aa[aa.count - 1 - i] != bb[bb.count - 1 - i] { n += 1 }
            n += abs(aa.count - bb.count)
            return n
        }
        var best: (String, AnafCompany, Double, Int)? = nil
        for (cui, comp) in found {
            let s = AnafClient.nameMatchScore(anafName: comp.denumire ?? "", ocrHeader: ocrHeader)
            let dist = digitDistance(cui, ocrForm)
            if best == nil
                || s > best!.2 + 0.05
                || (abs(s - best!.2) <= 0.05 && dist < best!.3)
                || (abs(s - best!.2) <= 0.05 && dist == best!.3 && cui.count < best!.0.count) {
                best = (cui, comp, s, dist)
            }
        }

        guard let (cui, comp, score, _) = best else {
            // Nimeni la ANAF: pastram CUI-ul citit daca are checksum, altfel incert.
            if checksumWasValid, let first = candidates.first {
                return (first, nil, 0, "cui_negasit_anaf")
            }
            return (nil, nil, 0,
                    candidates.isEmpty ? "fara_cui" : "cui_negasit_anaf")
        }

        // Scor pe nume: prag blând — pe termic antetul e zgomotos.
        // Daca scorul e 0 pentru toti, tot preferam cel mai apropiat de OCR (dist).
        if score >= 0.15 || found.count >= 1 {
            let repaired = !checksumWasValid || candidates.first != cui
            return (cui, comp, score,
                    repaired && score < 0.5 ? "confirmat_anaf_reparat" : "confirmat_anaf")
        }
        return (cui, comp, score, "cui_gasit_nume_diferit_verifica_manual")
    }
}
