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

    private static let chitantaTitleRx = try! NSRegularExpression(
        pattern: "\\bCH[I1L][T7L][A-ZĂÂÎȘȚ]{3,}\\b|(?:SERIE|SERIA|SERIC)\\s*[/\\-]?\\s*(?:NUMAR|NWUAR|NOMAR)",
        options: [.caseInsensitive])

    private static func looksLikeSingleChitanta(_ cluster: [OCRBoxItem]) -> Bool {
        let text = groupLines(cluster).joined(separator: " ").uppercased()
        if text.range(of: "BON\\s+FISCAL|TOTAL\\s*TVA|CASA\\s+DE\\s+MARCAT",
                      options: .regularExpression) != nil { return false }
        let range = NSRange(text.startIndex..., in: text)
        return chitantaTitleRx.firstMatch(in: text, range: range) != nil
            || (text.contains("PRIMIT DE LA") && text.contains("SUMA"))
    }

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
        merged = merged.flatMap { enforceOneHeader($0, medianHeight: mh) }
        merged = absorbOrphans(merged, medianHeight: mh)

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
        // Ancore robuste (validate pe poza de test cu 6 bonuri):
        //  - liniile cu CUI prefixat RO merg ca ancora chiar cand contextul e
        //    ilizibil ("Codl Identiticare Fiscala: R022254794");
        //  - antetul de firma (SRL/S.A./PFA) ancoreaza bonurile fara linie de CUI
        //    lizibila; liniile CLIENT raman excluse.
        let anchorRx: NSRegularExpression
        if looksLikeSingleChitanta(cluster) {
            anchorRx = chitantaTitleRx
        } else {
            anchorRx = try! NSRegularExpression(
                pattern: "NUMAR\\s*BON|COD\\s*FISCAL|COD\\s*IDENTIFICARE\\s*FISCALA|\\bC\\.?\\s*I\\.?\\s*F\\b|\\bCUI\\b|\\bR[O0]\\s?\\d{6,10}\\b|\\b(?:S\\.?\\s?R\\.?\\s?L\\.?|S\\.?A\\.?|P\\.?F\\.?A\\.?)\\b",
                options: [.caseInsensitive])
        }
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

    // MARK: - Invariante UNIVERSALE de segmentare (nu praguri reglate pe o poza)
    //
    //  (1) Un bon are UN SINGUR antet fiscal (NUMAR BON / COD FISCAL / linie RO+cifre).
    //      Doua CUI-uri distincte SAU doua grupuri de ancore tari => taietura fortata.
    //  (2) Un fragment FARA antet fiscal nu e document — apartine bonului vecin
    //      (footerul "MULTUMIM...", corpul unui bon cu antetul pe alt fragment etc.).
    //  Garda anti-fals-pozitiv: la ancore slabe, taietura se accepta doar daca
    //  AMBELE jumatati au antet fiscal propriu — un footer "VA MULTUMIM <FIRMA>"
    //  nu poate rupe un bon legitim in doua.

    static let strongAnchorRx = try! NSRegularExpression(
        pattern: "NUMAR\\s*BON|COD\\s*FISCAL|COD\\s*IDENTIFICARE\\s*FISCALA|\\bR[O0]\\s?\\d{6,10}\\b",
        options: [.caseInsensitive])
    private static let strongExclRx = try! NSRegularExpression(
        pattern: "CLIENT|CNP|CUMPARATOR|BENEF", options: [.caseInsensitive])

    static func hasFiscalHeader(_ c: [OCRBoxItem]) -> Bool {
        for l in groupLines(c) {
            let r = NSRange(l.startIndex..., in: l)
            if chitantaTitleRx.firstMatch(in: l, range: r) != nil { return true }
            if strongAnchorRx.firstMatch(in: l, range: r) != nil,
               strongExclRx.firstMatch(in: l, range: r) == nil { return true }
        }
        return false
    }

    private static func strongGroupCount(_ cluster: [OCRBoxItem], mh: Double) -> Int {
        var ys: [Double] = []
        for (y, t) in linesWithY(cluster) {
            let r = NSRange(t.startIndex..., in: t)
            if strongAnchorRx.firstMatch(in: t, range: r) != nil,
               strongExclRx.firstMatch(in: t, range: r) == nil { ys.append(y) }
        }
        ys.sort()
        var groups = 0
        var lastY = -Double.greatestFiniteMagnitude
        for y in ys {
            if y - lastY >= mh * 14 { groups += 1 }
            lastY = y
        }
        return groups
    }

    private static func chitantaHeaderGroupCount(_ cluster: [OCRBoxItem], mh: Double) -> Int {
        var ys: [Double] = []
        for (y, text) in linesWithY(cluster) {
            let range = NSRange(text.startIndex..., in: text)
            if chitantaTitleRx.firstMatch(in: text, range: range) != nil { ys.append(y) }
        }
        ys.sort()
        var groups = 0
        var lastY = -Double.greatestFiniteMagnitude
        for y in ys {
            if y - lastY >= mh * 10 { groups += 1 }
            lastY = y
        }
        return groups
    }

    private static func forceSplit(_ cluster: [OCRBoxItem], mh: Double,
                                   needBothHeaders: Bool) -> ([OCRBoxItem], [OCRBoxItem])? {
        func bestGap(alongX: Bool) -> (size: Double, split: Double)? {
            let intervals = cluster.map { alongX ? ($0.x, $0.x + $0.w) : ($0.y, $0.y + $0.h) }
                .sorted { $0.0 < $1.0 }
            var merged: [(Double, Double)] = [intervals[0]]
            for (a, b) in intervals.dropFirst() {
                if a <= merged[merged.count - 1].1 + 2 {
                    merged[merged.count - 1].1 = max(merged[merged.count - 1].1, b)
                } else { merged.append((a, b)) }
            }
            var best: (Double, Double)? = nil
            for i in 0..<(merged.count - 1) {
                let g = merged[i + 1].0 - merged[i].1
                if best == nil || g > best!.0 { best = (g, (merged[i].1 + merged[i + 1].0) / 2) }
            }
            return best
        }
        var candidates: [(alongX: Bool, size: Double, split: Double)] = []
        if let gx = bestGap(alongX: true), gx.size >= mh * 0.5 {
            candidates.append((true, gx.size, gx.split))
        }
        if let gy = bestGap(alongX: false), gy.size >= mh * 0.8 {
            candidates.append((false, gy.size, gy.split))
        }
        for cand in candidates.sorted(by: { $0.size > $1.size }) {
            let lo: [OCRBoxItem], hi: [OCRBoxItem]
            if cand.alongX {
                lo = cluster.filter { $0.x + $0.w / 2 < cand.split }
                hi = cluster.filter { $0.x + $0.w / 2 >= cand.split }
            } else {
                lo = cluster.filter { $0.y + $0.h / 2 < cand.split }
                hi = cluster.filter { $0.y + $0.h / 2 >= cand.split }
            }
            guard lo.count >= 10, hi.count >= 10 else { continue }
            if needBothHeaders && !(hasFiscalHeader(lo) && hasFiscalHeader(hi)) { continue }
            return (lo, hi)
        }
        return nil
    }

    static func enforceOneHeader(_ cluster: [OCRBoxItem], medianHeight mh: Double,
                                 depth: Int = 0) -> [[OCRBoxItem]] {
        // O chitanta contine legitim CUI emitent + CUI/CNP platitor. Doar doua
        // antete de chitanta permit split-ul; al doilea CUI nu este document nou.
        let isChitanta = looksLikeSingleChitanta(cluster)
        let multiCui = !isChitanta && merchantCuiHints(cluster).count >= 2
        let multiHdr = isChitanta
            ? chitantaHeaderGroupCount(cluster, mh: mh) >= 2
            : strongGroupCount(cluster, mh: mh) >= 2
        guard depth <= 6, multiCui || multiHdr else { return [cluster] }
        guard let (lo, hi) = forceSplit(cluster, mh: mh, needBothHeaders: !multiCui) else {
            return [cluster]
        }
        return enforceOneHeader(lo, medianHeight: mh, depth: depth + 1)
             + enforceOneHeader(hi, medianHeight: mh, depth: depth + 1)
    }

    static func absorbOrphans(_ clusters: [[OCRBoxItem]],
                              medianHeight mh: Double) -> [[OCRBoxItem]] {
        var anchored: [[OCRBoxItem]] = []
        var orphans: [[OCRBoxItem]] = []
        for c in clusters {
            if hasFiscalHeader(c) { anchored.append(c) } else { orphans.append(c) }
        }
        guard !anchored.isEmpty else { return clusters }
        for o in orphans {
            let ob = bbox(o)
            var bestIdx = -1
            var bestTier = Int.max
            var bestDist = Double.greatestFiniteMagnitude
            for (i, a) in anchored.enumerated() {
                let ab = bbox(a)
                let inter = min(ob.maxX, ab.maxX) - max(ob.minX, ab.minX)
                let minw = min(ob.maxX - ob.minX, ab.maxX - ab.minX)
                let xov = (inter > 0 && minw > 0) ? inter / minw : 0
                let vgap = max(ab.minY - ob.maxY, ob.minY - ab.maxY, 0)
                let hgap = max(ab.minX - ob.maxX, ob.minX - ab.maxX, 0)
                let tier = xov > 0.3 ? 0 : 1
                let dist = tier == 0 ? vgap : (vgap * vgap + hgap * hgap).squareRoot()
                if tier < bestTier || (tier == bestTier && dist < bestDist) {
                    bestTier = tier; bestDist = dist; bestIdx = i
                }
            }
            if bestIdx >= 0, bestDist <= mh * 20 {
                anchored[bestIdx].append(contentsOf: o)
            }
        }
        return anchored
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
