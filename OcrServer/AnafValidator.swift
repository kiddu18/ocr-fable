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
            let stop: Set<String> = ["SRL", "S.R.L", "THE", "COM", "PROD", "IMPEX", "GROUP"]
            return Set(s.uppercased()
                .replacingOccurrences(of: "[^A-Z0-9 ]", with: " ", options: .regularExpression)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) })
        }
        let a = tokens(anafName), b = tokens(ocrHeader)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
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
        // de antetul bonului (ex. "MOL ROMANIA..." vs candidati trunchiati).
        var best: (String, AnafCompany, Double)? = nil
        for (cui, comp) in found {
            let s = AnafClient.nameMatchScore(anafName: comp.denumire ?? "", ocrHeader: ocrHeader)
            if best == nil || s > best!.2 { best = (cui, comp, s) }
        }

        guard let (cui, comp, score) = best else {
            // Nimeni la ANAF: pastram CUI-ul citit daca are checksum, altfel incert.
            if checksumWasValid, let first = candidates.first {
                return (first, nil, 0, "cui_negasit_anaf")
            }
            return (nil, nil, 0,
                    candidates.isEmpty ? "fara_cui" : "cui_negasit_anaf")
        }

        // Scor pe nume: prag blând — pe termic antetul e zgomotos.
        if score >= 0.20 || found.count >= 1 {
            let repaired = !checksumWasValid || candidates.first != cui
            return (cui, comp, score,
                    repaired && score < 0.5 ? "confirmat_anaf_reparat" : "confirmat_anaf")
        }
        return (cui, comp, score, "cui_gasit_nume_diferit_verifica_manual")
    }
}
