//
//  ChitantaExtractor.swift
//  OcrServer
//
//  Procesator pentru CHITANTE DE MANA (formular tipizat completat de mana).
//
//  Realitate importanta: recunoasterea scrisului de mana in Apple Vision e
//  oficial suportata doar pentru un set restrans de limbi; romana cu diacritice
//  scrisa cursiv va iesi imperfect. Design-ul compenseaza asa:
//
//   1. ANCORELE sunt textul TIPARIT al formularului (CHITANTA, Nr., Data,
//      Am primit de la, Suma de, adica, Reprezentand) — tiparul se citeste
//      aproape perfect. Valorile scrise de mana se extrag din ZONA de dupa
//      fiecare ancora (aceeasi linie / pana la ancora urmatoare).
//   2. DUBLA VALIDARE INTERNA: suma in CIFRE vs suma in LITERE. Parserul
//      RoNumberWords transforma "douasutecincizeci lei" in 250.00; daca cele
//      doua surse coincid => sumaConfirmata = true. E echivalentul checksum-ului
//      de la CUI, dar pentru bani.
//   3. DOUA TRECERI OCR pe acelasi crop:
//        - una cu usesLanguageCorrection = true + customWords (numerele in
//          litere romanesti) -> pentru textul de mana;
//        - una cu usesLanguageCorrection = false -> pentru cifre (corectorul
//          lingvistic strica numerele).
//      Zonele numerice se citesc din trecerea fara corectie, textul din cealalta.
//   4. CNP-ul platitorului (13 cifre) are propriul checksum (cheia 279146358279),
//      validat local, la fel ca CUI-ul.
//
//  Contabil: chitanta e document de incasare/plata in NUMERAR. Singura,
//  NU da drept de deducere TVA — deducerea cere factura la care e atasata.
//  Perspectiva implicita: firma ta e PLATITORUL (chitanta primita ca dovada
//  de plata) => 401 = 5311. Daca firma e emitentul: 5311 = 4111.
//

import Foundation
import Vision
import CoreGraphics

// MARK: - DTO

struct ChitantaResult: Codable {
    var serie: String?
    var numar: String?
    var date: String?                 // yyyy-MM-dd

    // Partile — AMBELE sunt necesare in contabilitate:
    // firma X = emitentul (a PRIMIT banii, antetul tiparit sus)
    // firma Y = platitorul ("Am primit de la ...")
    var emitentNume: String?
    var emitentCui: String?
    var emitentCuiValid: Bool = false
    var emitentRegCom: String?        // ex. J40/1234/2020
    var emitentAnaf: AnafInfoDTO = AnafInfoDTO()

    var platitorNume: String?
    var platitorCui: String?
    var platitorCnp: String?
    var platitorCuiValid: Bool = false
    var platitorAnaf: AnafInfoDTO = AnafInfoDTO()

    var directie: String?             // "plata" / "incasare", raportat la CUI-ul firmei tale
    var facturaReferinta: String?     // "c/v factura nr. ..." — legatura pentru deducerea TVA

    /// Candidati CUI emitent pentru batch-ul ANAF (cand checksum-ul pica).
    var anafCandidatesEmitent: [String] = []

    var sumaCifre: Double?
    var sumaLitere: Double?           // parsata din "adica ..."
    var sumaLitereText: String?
    var suma: Double?                 // valoarea finala
    var sumaConfirmata: Bool = false  // cifre == litere
    var currency: String = "RON"

    var reprezentand: String?

    var suggestedAccount: String?
    var accountingNote: String?
    var entries: [AccountingEntryDTO] = []

    var warnings: [String] = []
    var confidence: Double = 0
    var rawText: String = ""
}

// MARK: - Suma in litere -> numar (romana)

enum RoNumberWords {

    /// "douasutecincizecisicinci lei si 50 bani" -> 255.50
    /// Tolerant la: diacritice, spatii lipsa (scris legat), cratime, "si", "de".
    static func parse(_ raw: String) -> Double? {
        var s = raw.lowercased()
        // diacritice si zgomot
        let map: [Character: Character] = ["ă": "a", "â": "a", "î": "i", "ș": "s", "ş": "s", "ț": "t", "ţ": "t"]
        s = String(s.map { map[$0] ?? $0 })
        s = s.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        guard !s.isEmpty else { return nil }

        // bani (zecimale): "...leisicincizecibani" / "...si50bani"
        var cents = 0.0
        if let r = s.range(of: "lei") {
            let tail = String(s[r.upperBound...])
            if tail.contains("bani") {
                let baniPart = tail.replacingOccurrences(of: "bani", with: "")
                    .replacingOccurrences(of: "si", with: "")
                if let d = Double(baniPart.filter { $0.isNumber }), d < 100 { cents = d / 100 }
                else if let w = parseInteger(baniPart), w < 100 { cents = Double(w) / 100 }
            }
            s = String(s[..<r.lowerBound])
        }
        // uneori suma e scrisa direct cu cifre in zona "adica"
        if let d = Double(s), d > 0 { return d + cents }
        guard let intPart = parseInteger(s), intPart > 0 else { return nil }
        return Double(intPart) + cents
    }

    /// Scanare greedy (cel mai lung token intai) peste textul lipit.
    private static func parseInteger(_ s0: String) -> Int? {
        // (token, valoare, esteMultiplicator)
        let tokens: [(String, Int, Bool)] = [
            ("saptesprezece", 17, false), ("saptisprezece", 17, false),
            ("optsprezece", 18, false), ("nouasprezece", 19, false),
            ("cincisprezece", 15, false), ("saisprezece", 16, false), ("sasesprezece", 16, false),
            ("paisprezece", 14, false), ("patrusprezece", 14, false),
            ("treisprezece", 13, false), ("doisprezece", 12, false), ("douasprezece", 12, false),
            ("unsprezece", 11, false),
            ("douazeci", 20, false), ("treizeci", 30, false), ("patruzeci", 40, false),
            ("cincizeci", 50, false), ("saizeci", 60, false), ("sasezeci", 60, false),
            ("saptezeci", 70, false), ("optzeci", 80, false), ("nouazeci", 90, false),
            ("sute", 100, true), ("suta", 100, true),
            ("miilioane", 1_000_000, true), ("milioane", 1_000_000, true), ("milion", 1_000_000, true),
            ("mii", 1000, true), ("mie", 1000, true),
            ("patru", 4, false), ("cinci", 5, false), ("sapte", 7, false),
            ("noua", 9, false), ("zece", 10, false), ("trei", 3, false),
            ("sase", 6, false), ("sai", 6, false), ("opt", 8, false),
            ("doua", 2, false), ("doi", 2, false),
            ("unu", 1, false), ("una", 1, false), ("un", 1, false), ("o", 1, false),
            ("si", 0, false), ("de", 0, false), ("lei", 0, false),
        ]
        var s = Substring(s0)
        var total = 0, current = 0
        var matchedAny = false
        while !s.isEmpty {
            var matched = false
            for (tok, val, isMult) in tokens where s.hasPrefix(tok) {
                s = s.dropFirst(tok.count)
                matched = true
                if val == 0 { break }               // conjunctii
                matchedAny = true
                if isMult {
                    if val >= 1000 { total += max(current, 1) * val; current = 0 }
                    else { current = max(current, 1) * val }        // sute
                } else {
                    current += val
                }
                break
            }
            if !matched { s = s.dropFirst() }        // caracter nerecunoscut (eroare OCR) — sarim
        }
        let result = total + current
        return (matchedAny && result > 0) ? result : nil
    }

    /// customWords pentru trecerea OCR cu corectie — ajuta Vision la scrisul de mana.
    static let customWords: [String] = [
        "unu", "doi", "două", "trei", "patru", "cinci", "șase", "șapte", "opt", "nouă", "zece",
        "unsprezece", "doisprezece", "treisprezece", "paisprezece", "cincisprezece", "șaisprezece",
        "șaptesprezece", "optsprezece", "nouăsprezece", "douăzeci", "treizeci", "patruzeci",
        "cincizeci", "șaizeci", "șaptezeci", "optzeci", "nouăzeci", "sută", "sute", "mie", "mii",
        "lei", "bani", "adică", "reprezentând", "chitanța", "chitanță", "numerar", "suma", "primit",
    ]
}

// MARK: - CNP (13 cifre, checksum propriu)

enum RoCNP {
    static func isValid(_ cnp: String) -> Bool {
        let d = cnp.compactMap { $0.wholeNumberValue }
        guard d.count == 13 else { return false }
        let key = [2, 7, 9, 1, 4, 6, 3, 5, 8, 2, 7, 9]
        let sum = zip(d, key).map(*).reduce(0, +)
        var c = sum % 11
        if c == 10 { c = 1 }
        return c == d[12]
    }
}

// MARK: - Extractorul de chitante

enum ChitantaExtractor {

    /// Un document e chitanta (nu bon fiscal) daca are "CHITANTA" si NU are
    /// markerii de casa de marcat.
    static func looksLikeChitanta(_ text: String) -> Bool {
        let t = text.uppercased()
            .replacingOccurrences(of: "Ț", with: "T").replacingOccurrences(of: "Ă", with: "A")
        return t.contains("CHITANTA")
            && !t.contains("BON FISCAL") && !t.contains("TOTAL TVA") && !t.contains("CASA DE MARCAT")
    }

    /// `linesText`   = linii din trecerea CU corectie lingvistica (text de mana)
    /// `linesDigits` = linii din trecerea FARA corectie (cifre curate)
    /// `myCui`       = CUI-ul firmei tale — decide directia (plata vs incasare)
    static func extract(linesText: [String], linesDigits: [String],
                        myCui: String? = nil) -> ChitantaResult {
        var r = ChitantaResult()
        r.rawText = linesText.joined(separator: "\n")
        var warnings: [String] = []

        // --- impartirea in zone: tot ce e DEASUPRA "Am primit de la" = emitentul
        func primitIndex(_ lines: [String]) -> Int {
            lines.firstIndex { normalize($0).contains("PRIMIT DE LA") } ?? lines.count
        }
        let issuerLinesT = Array(linesText.prefix(primitIndex(linesText)))
        let issuerLinesD = Array(linesDigits.prefix(primitIndex(linesDigits)))
        let payerLinesD  = Array(linesDigits.dropFirst(primitIndex(linesDigits)))

        func zone(after anchors: [String], in lines: [String], stopBefore: [String] = []) -> String? {
            for (i, line) in lines.enumerated() {
                let up = normalize(line)
                guard let a = anchors.first(where: { up.contains($0) }) else { continue }
                var value = String(up[up.range(of: a)!.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .:_-"))
                // valoarea poate continua pe linia urmatoare (scris mare, de mana)
                if value.count < 3, i + 1 < lines.count {
                    let next = normalize(lines[i + 1])
                    if !stopBefore.contains(where: { next.contains($0) }) { value = next }
                }
                if let stop = stopBefore.compactMap({ value.range(of: $0)?.lowerBound }).min() {
                    value = String(value[..<stop])
                }
                return value.isEmpty ? nil : value
            }
            return nil
        }

        // --- serie / numar / data (tiparite sau scrise, cifrele din trecerea fara corectie)
        r.serie = zone(after: ["SERIA", "SERIE"], in: linesDigits, stopBefore: ["NR", "NUMAR"])?
            .components(separatedBy: " ").first
        if let nr = zone(after: ["NR", "NUMAR"], in: linesDigits, stopBefore: ["DATA", "DIN"]) {
            r.numar = nr.filter { $0.isNumber }.isEmpty ? nr : String(nr.filter { $0.isNumber }.prefix(8))
        }
        r.date = parseDate(linesDigits)

        // --- EMITENTUL (firma X, care a primit banii) — antetul tiparit
        r.emitentNume = zone(after: ["UNITATEA", "FURNIZOR", "SOCIETATEA"], in: issuerLinesT,
                             stopBefore: ["CUI", "CIF", "COD FISCAL", "NR", "ADRESA"])
        if r.emitentNume == nil {
            // fallback: prima linie din antet cu forma juridica, sarind peste "CHITANTA"
            let legal = try! NSRegularExpression(
                pattern: "\\b(S\\.?\\s?R\\.?\\s?L\\.?|S\\.?A\\.?|P\\.?F\\.?A\\.?|I\\.?I\\.?)(\\b|$)",
                options: [.caseInsensitive])
            for line in issuerLinesT where !normalize(line).contains("CHITANTA") {
                let range = NSRange(line.startIndex..., in: line)
                if legal.firstMatch(in: line, range: range) != nil {
                    r.emitentNume = line.trimmingCharacters(in: .whitespaces); break
                }
            }
        }

        // CUI emitent: refolosim exact motorul de la bonuri (checksum + reparare OCR)
        let emitCui = RoCUI.extract(fromLines: issuerLinesD, buyerCui: nil)
        r.emitentCui = emitCui.best
        r.emitentCuiValid = emitCui.checksumOK
        r.anafCandidatesEmitent = emitCui.checksumOK ? [emitCui.best!] : emitCui.candidates
        if r.emitentCui == nil && r.anafCandidatesEmitent.isEmpty {
            warnings.append("CUI-ul emitentului nu a fost gasit in antet — obligatoriu pentru inregistrare.")
        }

        // Nr. Reg. Com. (J40/1234/2020)
        let regRx = try! NSRegularExpression(pattern: "\\b([JCF])\\s?(\\d{1,2})\\s?/\\s?(\\d{1,8})\\s?/\\s?(20\\d{2}|19\\d{2})\\b",
                                             options: [.caseInsensitive])
        for line in issuerLinesD {
            let up = normalize(line)
            let range = NSRange(up.startIndex..., in: up)
            if let m = regRx.firstMatch(in: up, range: range) {
                let ns = up as NSString
                r.emitentRegCom = "\(ns.substring(with: m.range(at: 1)))\(ns.substring(with: m.range(at: 2)))/\(ns.substring(with: m.range(at: 3)))/\(ns.substring(with: m.range(at: 4)))"
                break
            }
        }

        // --- PLATITORUL (firma Y): "Am primit de la ..."
        r.platitorNume = zone(after: ["AM PRIMIT DE LA", "PRIMIT DE LA"], in: linesText,
                              stopBefore: ["CUI", "CNP", "CIF", "ADRESA", "SUMA"])

        // CUI / CNP platitor — DOAR din zona de sub "Am primit de la",
        // ca sa nu-l confundam cu CUI-ul emitentului din antet
        for line in payerLinesD {
            let up = normalize(line)
            guard up.contains("CNP") || up.contains("CUI") || up.contains("CIF") else { continue }
            let digits = String(RoCUI.repairOCRDigits(up).filter { $0.isNumber })
            if digits.count >= 13 {
                let cnp = String(digits.prefix(13))
                r.platitorCnp = cnp
                r.platitorCuiValid = RoCNP.isValid(cnp)
                if !r.platitorCuiValid { warnings.append("CNP-ul platitorului nu trece checksum-ul — verifica manual.") }
            } else if digits.count >= 4 {
                r.platitorCui = digits
                r.platitorCuiValid = RoCUI.isValid(digits)
                if !r.platitorCuiValid { warnings.append("CUI-ul platitorului nu trece checksum-ul — verifica manual.") }
            }
            break
        }

        // --- suma in cifre (fara corectie lingvistica)
        for line in linesDigits {
            let up = normalize(line)
            guard up.contains("SUMA") || up.contains("LEI") else { continue }
            if let v = FinExtract.amounts(in: line).first { r.sumaCifre = v; break }
        }
        if r.sumaCifre == nil {
            // fallback: orice suma cu format bani de pe chitanta
            r.sumaCifre = linesDigits.flatMap { FinExtract.amounts(in: $0) }.max()
            if r.sumaCifre != nil { warnings.append("Suma in cifre luata fara ancora 'Suma de' — verifica.") }
        }

        // --- suma in litere: zona "adica ..." (cu corectie + customWords)
        if let lit = zone(after: ["ADICA"], in: linesText, stopBefore: ["REPREZENTAND", "REPREZENT"]) {
            r.sumaLitereText = lit
            r.sumaLitere = RoNumberWords.parse(lit)
        }

        // --- dubla validare cifre vs litere (echivalentul checksum-ului, pentru bani)
        switch (r.sumaCifre, r.sumaLitere) {
        case let (c?, l?):
            if abs(c - l) < 0.01 {
                r.suma = c; r.sumaConfirmata = true
            } else {
                r.suma = c
                warnings.append("Suma in cifre (\(c)) difera de suma in litere (\(l)) — chitanta trebuie verificata manual.")
            }
        case let (c?, nil):
            r.suma = c
            warnings.append("Suma in litere nu a putut fi citita/parsata — fara dubla validare.")
        case let (nil, l?):
            r.suma = l
            warnings.append("Suma in cifre nu a fost citita; folosita suma din litere.")
        default:
            warnings.append("Suma nu a putut fi citita deloc.")
        }

        // --- reprezentand + legatura cu factura (esentiala pentru deducerea TVA)
        r.reprezentand = zone(after: ["REPREZENTAND", "REPREZENT"], in: linesText,
                              stopBefore: ["CASIER", "SEMNATURA"])
        if let rep = r.reprezentand ?? linesText.last {
            let fRx = try! NSRegularExpression(
                pattern: "(?:C/?V\\s*)?(?:FACTURA|FACT|FCT|FF)\\s*(?:FISCALA)?\\s*(?:NR|NUMAR)?\\s*[.:#]?\\s*([A-Z]{0,4}\\s?\\d{1,10})",
                options: [.caseInsensitive])
            let up = normalize(rep)
            let range = NSRange(up.startIndex..., in: up)
            if let m = fRx.firstMatch(in: up, range: range), m.range(at: 1).location != NSNotFound {
                r.facturaReferinta = (up as NSString).substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // --- directia: cine e firma ta pe chitanta asta?
        let mine = myCui.map { String($0.filter { c in c.isNumber }) }
        if let mine, !mine.isEmpty {
            if mine == r.emitentCui { r.directie = "incasare" }
            else if mine == r.platitorCui { r.directie = "plata" }
            else {
                warnings.append("CUI-ul firmei tale (\(mine)) nu apare pe chitanta nici ca emitent, nici ca platitor — verifica.")
            }
        }

        // --- monografia, in functie de directie
        if let s = r.suma, s > 0 {
            if r.directie == "incasare" {
                r.suggestedAccount = "5311 = 4111"
                r.accountingNote = "Firma ta e EMITENTUL: incasare numerar de la client"
                    + (r.platitorNume.map { " (\($0))" } ?? "") + "."
                r.entries = [AccountingEntryDTO(debit: "5311", credit: "4111", amount: s.ron2,
                                                label: "Incasare numerar conform chitanta"
                                                    + (r.numar.map { " nr. \($0)" } ?? ""))]
            } else {
                r.suggestedAccount = "401 = 5311"
                r.accountingNote = "Firma ta e PLATITORUL: plata numerar catre furnizor"
                    + (r.emitentNume.map { " (\($0))" } ?? "")
                    + ". Chitanta singura NU da drept de deducere TVA — deducerea cere factura"
                    + (r.facturaReferinta.map { " (referinta gasita: \($0))" } ?? " aferenta") + "."
                r.entries = [AccountingEntryDTO(debit: "401", credit: "5311", amount: s.ron2,
                                                label: "Plata numerar conform chitanta"
                                                    + (r.numar.map { " nr. \($0)" } ?? ""))]
            }
            // plafoanele de numerar (Legea 70/2015): 5.000 lei/zi/persoana la plati
            // intre firme, 10.000 lei/zi la incasari de la persoane fizice
            if s > 5000 {
                warnings.append("Suma depaseste plafonul de numerar de 5.000 lei/zi (Legea 70/2015) pentru operatiuni intre firme.")
            }
        }

        // --- incredere
        var c = 0.25
        if r.sumaConfirmata { c += 0.30 }
        if r.emitentCuiValid { c += 0.10 }
        if r.platitorCuiValid { c += 0.10 }
        if r.date != nil { c += 0.10 }
        if r.numar != nil { c += 0.05 }
        if r.platitorNume != nil { c += 0.05 }
        c -= Double(warnings.count) * 0.05
        r.confidence = min(1, max(0, c)).ron2
        r.warnings = warnings
        return r
    }

    private static func normalize(_ s: String) -> String {
        let map: [Character: Character] = ["Ă": "A", "Â": "A", "Î": "I", "Ș": "S", "Ş": "S",
                                            "Ț": "T", "Ţ": "T"]
        return String(s.uppercased().map { map[$0] ?? $0 })
    }

    private static func parseDate(_ lines: [String]) -> String? {
        let rx = try! NSRegularExpression(pattern: "\\b(\\d{1,2})[./-](\\d{1,2})[./-](20\\d{2})\\b")
        for line in lines {
            let r = NSRange(line.startIndex..., in: line)
            guard let m = rx.firstMatch(in: line, range: r) else { continue }
            let ns = line as NSString
            let d = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let mo = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let y = Int(ns.substring(with: m.range(at: 3))) ?? 0
            guard (1...31).contains(d), (1...12).contains(mo) else { continue }
            return String(format: "%04d-%02d-%02d", y, mo, d)
        }
        return nil
    }
}

// MARK: - OCR in doua treceri pentru scris de mana

extension TextRecognizerPro {

    /// Trecere OCR dedicata scrisului de mana: usesLanguageCorrection = true
    /// + customWords cu numerele romanesti in litere.
    func handwritingPass(on image: CGImage) async -> [OCRBoxItem] {
        await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                var items: [OCRBoxItem] = []
                let W = Double(image.width), H = Double(image.height)
                for obs in (req.results as? [VNRecognizedTextObservation]) ?? [] {
                    guard let cand = obs.topCandidates(1).first else { continue }
                    let b = obs.boundingBox
                    items.append(OCRBoxItem(text: cand.string,
                                            x: b.minX * W, y: (1 - b.maxY) * H,
                                            w: b.width * W, h: b.height * H,
                                            rect: nil))
                }
                cont.resume(returning: items)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.customWords = RoNumberWords.customWords
            request.recognitionLanguages = ["ro-RO", "en-US"]
            if #available(iOS 16.0, macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
            }
        }
    }
}

// ============================ INTEGRARE ====================================
// In ruta POST /upload, dupa pasul 3 (crop + re-OCR per bon), inainte de
// ReceiptExtractor.extract, adauga bifurcatia:
//
//   let myCui = "30630040"   // CUI-ul firmei tale (config / camp in upload)
//   let rawLines = ReceiptSegmenterV2.groupLines(clean)          // fara corectie
//   if ChitantaExtractor.looksLikeChitanta(rawLines.joined(separator: "\n")) {
//       let hwWords = await pro.handwritingPass(on: cropImage)   // cu corectie
//       let hwLines = ReceiptSegmenterV2.groupLines(hwWords)
//       let ch = ChitantaExtractor.extract(linesText: hwLines,
//                                          linesDigits: rawLines,
//                                          myCui: myCui)
//       chitante.append(ch)                                       // camp separat in raspuns
//   } else {
//       receipts.append(ReceiptExtractor.extract(lines: rawLines, ...))
//   }
//
// La pasul 4 (batch-ul ANAF unic), adauga si CUI-urile chitantelor:
//
//   for ch in chitante {
//       allCandidates.append(contentsOf: ch.anafCandidatesEmitent)
//       if let p = ch.platitorCui, RoCUI.isValid(p) { allCandidates.append(p) }
//   }
//
// Iar la pasul 5, rezolva AMBELE parti (dubla validare CUI + denumire):
//
//   for i in chitante.indices {
//       let res = AnafResolver.resolve(candidates: chitante[i].anafCandidatesEmitent,
//                                      checksumWasValid: chitante[i].emitentCuiValid,
//                                      ocrHeader: chitante[i].emitentNume ?? "",
//                                      anaf: anafInfo)
//       chitante[i].emitentAnaf.status = res.status
//       chitante[i].emitentAnaf.nameScore = res.score
//       if let comp = res.company {
//           chitante[i].emitentCui = res.cui
//           chitante[i].emitentAnaf.found = true
//           chitante[i].emitentAnaf.denumire = comp.denumire
//           chitante[i].emitentAnaf.adresa = comp.adresa
//           chitante[i].emitentAnaf.scpTVA = comp.scpTVA
//       }
//       if let p = chitante[i].platitorCui, let comp = anafInfo[p] {
//           chitante[i].platitorAnaf.found = true
//           chitante[i].platitorAnaf.denumire = comp.denumire
//           chitante[i].platitorAnaf.status = "confirmat_anaf"
//           // dubla validare si pe nume, daca "Am primit de la" a fost citit:
//           if let nume = chitante[i].platitorNume {
//               chitante[i].platitorAnaf.nameScore =
//                   AnafClient.nameMatchScore(anafName: comp.denumire ?? "", ocrHeader: nume)
//           }
//       }
//   }
//
// In UploadResponse: let chitante: [ChitantaResult]?
// In WebClient: card cu ambele parti (Emitent / Platitor, fiecare cu badge ANAF),
// directia (plata/incasare), suma cu badge verde "Confirmata cifre = litere"
// cand sumaConfirmata == true, referinta la factura si monografia.
// ===========================================================================
