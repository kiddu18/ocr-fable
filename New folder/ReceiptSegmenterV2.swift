//
//  ReceiptSegmenterV2.swift
//  OcrServer
//
//  INLOCUIESTE ReceiptSegmenter din ReceiptPipelinePatch.swift.
//
//  Buguri reparate fata de versiunea veche:
//   1. Comparatorul de sortare `minX < minX || (abs(...) && minY < minY)` incalca
//      "strict weak ordering" => Swift poate da crash (precondition failure in sort)
//      sau ordine aleatoare. Inlocuit cu cheie lexicografica valida.
//   2. mergeFragments lipea bonuri vecine pe aceeasi coloana (toleranta mh*7 era
//      prea mare, iar regula "doua antete" era conditionata de gap). Acum:
//      - doua clustere care AMBELE arata a bon complet (CUI de comerciant sau
//        "NUMAR BON") nu se unesc NICIODATA;
//      - doua clustere cu CUI-uri de comerciant DIFERITE nu se unesc niciodata;
//      - toleranta verticala redusa la mh*4.
//   3. splitByHeaderAnchors se baza doar pe "NUMAR BON" — dar Douglas si ROG GAZ
//      nu au aceasta linie. Acum ancorele includ si linia de CUI a comerciantului
//      (COD FISCAL / C.I.F. / Cod Identificare Fiscala), pe care o are ORICE bon,
//      iar taietura se face la cel mai mare gol dintre linii, nu la offset fix.
//   4. Operatorul `<` pe tupluri definit la nivel de fisier intra in conflict cu
//      cel din biblioteca standard => eliminat.
//

import Foundation

enum ReceiptSegmenterV2 {

    // MARK: - API

    static func segment(_ words: [OCRBoxItem]) -> [[OCRBoxItem]] {
        guard !words.isEmpty else { return [] }
        let heights = words.map { $0.h }.sorted()
        let mh = max(heights[heights.count / 2], 4.0)

        var parts: [[OCRBoxItem]] = []
        xycut(words, minGapX: mh * 1.0, minGapY: mh * 1.5, into: &parts)
        parts = parts.filter { $0.count >= 8 }

        var merged = mergeFragments(parts, medianHeight: mh)
        merged = merged.flatMap { splitByAnchors($0, medianHeight: mh) }

        return merged.filter { $0.count >= 12 }
            .sorted { a, b in
                let ba = bbox(a), bb2 = bbox(b)
                let ka = Int((ba.minX / 400.0).rounded(.down))
                let kb = Int((bb2.minX / 400.0).rounded(.down))
                return ka != kb ? ka < kb : ba.minY < bb2.minY
            }
    }

    // MARK: - XY-cut recursiv (neschimbat ca idee)

    private static func xycut(_ ws: [OCRBoxItem], minGapX: Double, minGapY: Double,
                              into out: inout [[OCRBoxItem]]) {
        guard ws.count >= 10 else { out.append(ws); return }

        func bestGap(axis: Character) -> (size: Double, split: Double)? {
            let intervals = ws.map { axis == "x" ? ($0.x, $0.x + $0.w) : ($0.y, $0.y + $0.h) }
                .sorted { $0.0 < $1.0 }
            var merged: [(Double, Double)] = [intervals[0]]
            for (a, b) in intervals.dropFirst() {
                if a <= merged[merged.count - 1].1 + 2 {
                    merged[merged.count - 1].1 = max(merged[merged.count - 1].1, b)
                } else {
                    merged.append((a, b))
                }
            }
            var best: (Double, Double)? = nil
            for i in 0..<(merged.count - 1) {
                let g = merged[i + 1].0 - merged[i].1
                if best == nil || g > best!.0 { best = (g, (merged[i].1 + merged[i + 1].0) / 2) }
            }
            return best
        }

        let gx = bestGap(axis: "x"), gy = bestGap(axis: "y")
        let sx = gx?.size ?? 0, sy = gy?.size ?? 0
        if sx < minGapX && sy < minGapY { out.append(ws); return }

        if sx / minGapX >= sy / minGapY, let split = gx?.split {
            xycut(ws.filter { $0.x + $0.w / 2 < split }, minGapX: minGapX, minGapY: minGapY, into: &out)
            xycut(ws.filter { $0.x + $0.w / 2 >= split }, minGapX: minGapX, minGapY: minGapY, into: &out)
        } else if let split = gy?.split {
            xycut(ws.filter { $0.y + $0.h / 2 < split }, minGapX: minGapX, minGapY: minGapY, into: &out)
            xycut(ws.filter { $0.y + $0.h / 2 >= split }, minGapX: minGapX, minGapY: minGapY, into: &out)
        } else {
            out.append(ws)
        }
    }

    // MARK: - Unirea fragmentelor antet/corp din aceeasi coloana

    private static func mergeFragments(_ parts: [[OCRBoxItem]],
                                       medianHeight mh: Double) -> [[OCRBoxItem]] {
        var merged = parts
        var changed = true
        while changed {
            changed = false
            outer: for i in 0..<merged.count {
                for j in (i + 1)..<merged.count {
                    let a = bbox(merged[i]), b = bbox(merged[j])
                    let inter = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    let minW = min(a.maxX - a.minX, b.maxX - b.minX)
                    let xOverlap = (inter > 0 && minW > 0) ? inter / minW : 0
                    let vGap = max(b.minY - a.maxY, a.minY - b.maxY, 0)

                    // Regula 1: doua clustere care ambele arata a bon complet nu se unesc.
                    if looksLikeReceipt(merged[i]) && looksLikeReceipt(merged[j]) { continue }

                    // Regula 2: CUI-uri de comerciant diferite => bonuri diferite.
                    let ca = merchantCuiHints(merged[i]), cb = merchantCuiHints(merged[j])
                    if !ca.isEmpty && !cb.isEmpty && ca.isDisjoint(with: cb) { continue }

                    // Regula 3: toleranta verticala redusa (mh*7 lipea bonuri vecine).
                    if xOverlap > 0.5 && vGap < mh * 4 {
                        merged[i].append(contentsOf: merged[j])
                        merged.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return merged
    }

    /// Cluster care contine linia de CUI a comerciantului SAU "NUMAR BON"
    /// = foarte probabil un bon (sau macar antetul lui complet).
    private static func looksLikeReceipt(_ c: [OCRBoxItem]) -> Bool {
        if !merchantCuiHints(c).isEmpty { return true }
        let bonRx = try! NSRegularExpression(pattern: "NUMAR\\s*BON", options: [.caseInsensitive])
        for l in groupLines(c) {
            if bonRx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { return true }
        }
        return false
    }

    // MARK: - Split pe ancore: fiecare bon are exact o linie de CUI de comerciant

    static func splitByAnchors(_ cluster: [OCRBoxItem],
                               medianHeight mh: Double) -> [[OCRBoxItem]] {
        let lines = linesWithY(cluster)
        let anchorRx = try! NSRegularExpression(
            pattern: "NUMAR\\s*BON|COD\\s*FISCAL|COD\\s*IDENTIFICARE\\s*FISCALA|\\bC\\.?\\s*I\\.?\\s*F\\b|\\bCUI\\b",
            options: [.caseInsensitive])
        let excludeRx = try! NSRegularExpression(pattern: "CLIENT|CNP|CUMPARATOR|BENEF",
                                                 options: [.caseInsensitive])

        var anchorYs: [Double] = []
        for l in lines {
            let r = NSRange(l.text.startIndex..., in: l.text)
            if anchorRx.firstMatch(in: l.text, range: r) != nil,
               excludeRx.firstMatch(in: l.text, range: r) == nil {
                anchorYs.append(l.y)
            }
        }
        anchorYs.sort()

        // Ancorele apropiate apartin aceluiasi antet (CUI + NUMAR BON sunt vecine).
        var groups: [Double] = []
        for y in anchorYs {
            if let g = groups.last, y - g < mh * 12 { continue }
            groups.append(y)
        }
        guard groups.count >= 2 else { return [cluster] }

        // Taiem la cel mai mare gol dintre linii, intre fiecare pereche de ancore.
        var cuts: [Double] = []
        for k in 0..<(groups.count - 1) {
            let lo = groups[k], hi = groups[k + 1]
            let inBetween = lines.map { $0.y }.filter { $0 > lo && $0 < hi }.sorted()
            let seq = [lo] + inBetween + [hi]
            var bestGap = -1.0
            var bestCut = (lo + hi) / 2
            for m in 0..<(seq.count - 1) {
                let gap = seq[m + 1] - seq[m]
                if gap > bestGap { bestGap = gap; bestCut = (seq[m] + seq[m + 1]) / 2 }
            }
            cuts.append(bestCut)
        }

        var parts = Array(repeating: [OCRBoxItem](), count: cuts.count + 1)
        for w in cluster {
            let c = w.y + w.h / 2
            var k = 0
            for (ci, cut) in cuts.enumerated() where c >= cut { k = ci + 1 }
            parts[k].append(w)
        }
        return parts.filter { $0.count >= 10 }
    }

    // MARK: - CUI-urile de comerciant dintr-un cluster (exclude liniile CLIENT/CNP)

    static func merchantCuiHints(_ cluster: [OCRBoxItem]) -> Set<String> {
        var out: Set<String> = []
        let ctx = try! NSRegularExpression(
            pattern: "(?:COD\\s*FISCAL|COD\\s*IDENTIFICARE\\s*FISCALA|\\bC\\.?\\s*I\\.?\\s*F\\b|\\bCUI\\b)\\s*[.:]?\\s*(?:R[O0])?\\s*([0-9OQDILSZB@]{4,12})",
            options: [.caseInsensitive])
        let excl = try! NSRegularExpression(pattern: "CLIENT|CNP|CUMPARATOR|BENEF",
                                            options: [.caseInsensitive])
        for line in groupLines(cluster) {
            let r = NSRange(line.startIndex..., in: line)
            guard excl.firstMatch(in: line, range: r) == nil else { continue }
            for m in ctx.matches(in: line, range: r) where m.range(at: 1).location != NSNotFound {
                let raw = (line as NSString).substring(with: m.range(at: 1))
                let digits = RoCUI.repairOCRDigits(raw).filter { $0.isNumber }
                if digits.count >= 4 { out.insert(String(digits)) }
            }
        }
        return out
    }

    // MARK: - Gruparea cuvintelor in linii (folosita si de ReceiptExtractor)

    static func groupLines(_ words: [OCRBoxItem]) -> [String] {
        linesWithY(words).map { $0.text }
    }

    static func linesWithY(_ words: [OCRBoxItem]) -> [(y: Double, text: String)] {
        guard !words.isEmpty else { return [] }
        let hs = words.map { $0.h }.sorted()
        let mh = max(hs[hs.count / 2], 4.0)
        let sorted = words.sorted { a, b in
            let ca = a.y + a.h / 2, cb = b.y + b.h / 2
            return ca != cb ? ca < cb : a.x < b.x
        }
        var lines: [[OCRBoxItem]] = []
        var centers: [Double] = []
        for w in sorted {
            let c = w.y + w.h / 2
            if let last = centers.last, abs(c - last) < mh * 0.7 {
                lines[lines.count - 1].append(w)
                let n = Double(lines[lines.count - 1].count)
                centers[centers.count - 1] = (last * (n - 1) + c) / n
            } else {
                lines.append([w])
                centers.append(c)
            }
        }
        return zip(centers, lines).map { (y, ws) in
            (y, ws.sorted { $0.x < $1.x }.map { $0.text }.joined(separator: " "))
        }
    }

    // MARK: - Helpers

    static func bbox(_ c: [OCRBoxItem]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (c.map { $0.x }.min() ?? 0, c.map { $0.y }.min() ?? 0,
         c.map { $0.x + $0.w }.max() ?? 0, c.map { $0.y + $0.h }.max() ?? 0)
    }
}
