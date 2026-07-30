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
//   3. splitByHeaderAnchors se baza doar pe "NUMAR BON" — unele bonuri (parfumerie,
//      GPL, format scurt) nu au aceasta linie. Ancorele includ si linia de CUI
//      (COD FISCAL / C.I.F. / Cod Identificare Fiscala), pe care o are ORICE bon,
//      iar taietura se face la cel mai mare gol dintre linii, nu la offset fix.
//   4. Operatorul `<` pe tupluri definit la nivel de fisier intra in conflict cu
//      cel din biblioteca standard => eliminat.
//

import Foundation

enum ReceiptSegmenterV2 {

    private static let chitantaTitleRx = try! NSRegularExpression(
        pattern: "\\bCH[I1L][T7L][A-ZĂÂÎȘȚ]{3,}\\b|(?:SERIE|SERIA|SERIC)\\s*[/\\-]?\\s*(?:NUMAR|NWUAR|NOMAR|TOMNAR|NOUAR|NHONAR|ANAR)",
        options: [.caseInsensitive])

    private static func looksLikeSingleChitanta(_ cluster: [OCRBoxItem]) -> Bool {
        let text = groupLines(cluster).joined(separator: " ").uppercased()
        return ChitantaExtractor.looksLikeChitanta(text)
    }

    // MARK: - API

    static func segment(_ words: [OCRBoxItem]) -> [[OCRBoxItem]] {
        guard !words.isEmpty else { return [] }

        // Vision poate recunoaste textul unui bon rotit, dar pastreaza box-urile
        // verticale. Replay-ul offline normaliza deja acest caz; pipeline-ul Swift
        // nu o facea si unea cate doua bonuri intr-o singura coloana (6 -> 3).
        // Segmentam in spatiul normalizat, apoi mapam fiecare box inapoi pentru crop.
        let verticalCount = words.filter { $0.h > $0.w && $0.text.count > 2 }.count
        let needsRotation = verticalCount > words.count / 2
        let originalHMax = words.map { $0.y + $0.h }.max() ?? 0
        let input: [OCRBoxItem]
        if needsRotation {
            input = words.map { word in
                OCRBoxItem(text: word.text,
                           x: originalHMax - (word.y + word.h), y: word.x,
                           w: word.h, h: word.w, rect: nil)
            }
        } else {
            input = words
        }

        let heights = input.map { $0.h }.sorted()
        let mh = max(heights[heights.count / 2], 4.0)

        var parts: [[OCRBoxItem]] = []
        xycut(input, minGapX: mh * 1.0, minGapY: mh * 1.5, into: &parts)
        // Un bloc lateral "CHITANTA / Serie / Numar / Data" poate avea doar
        // 4-7 cuvinte; il pastram pentru reunirea semantica de mai jos.
        // CRITICAL: pe Douglas, totalul (613.10 / 106.41) iese pe o "insula"
        // de 4–6 cuvinte la dreapta, din cauza golului XY-cut. Daca il aruncam
        // aici, absorbOrphans nu mai are ce lipi pe bon → total gol in UI.
        parts = parts.filter { part in
            if part.count >= 8 { return true }
            return isValuableFragment(part)
        }

        var merged = mergeFragments(parts, medianHeight: mh)
        merged = merged.flatMap { splitByAnchors($0, medianHeight: mh) }
        merged = merged.flatMap { enforceOneHeader($0, medianHeight: mh) }
        merged = absorbOrphans(merged, medianHeight: mh)

        let ordered = merged.filter { $0.count >= 12 }
            .sorted { a, b in
                let ba = bbox(a), bb2 = bbox(b)
                let ka = Int((ba.minX / 400.0).rounded(.down))
                let kb = Int((bb2.minX / 400.0).rounded(.down))
                return ka != kb ? ka < kb : ba.minY < bb2.minY
            }
        let result = ordered.flatMap { splitSideBySideDocuments($0, medianHeight: mh) }
        guard needsRotation else { return result }
        return result.map { cluster in
            cluster.map { word in
                OCRBoxItem(text: word.text,
                           x: word.y, y: originalHMax - (word.x + word.w),
                           w: word.h, h: word.w, rect: nil)
            }
        }
    }

    /// Doua bonuri alaturate pot avea un spatiu foarte mic intre ele, astfel
    /// incat proiectia XY-cut devine continua. Folosim doar pozitiile tokenilor
    /// de antet fiscal pentru a propune taieturi si acceptam taietura numai daca
    /// ambele jumatati sunt documente complete (antet + total/footer fiscal).
    private static func splitSideBySideDocuments(_ cluster: [OCRBoxItem],
                                                  medianHeight mh: Double,
                                                  depth: Int = 0) -> [[OCRBoxItem]] {
        guard depth < 4, cluster.count >= 24,
              !looksLikeSingleChitanta(cluster) else { return [cluster] }
        let tokenRx = try! NSRegularExpression(
            pattern: "^(?:NUMAR|COD|FISCAL|CUI|CIF|R[O0][0-9OQDILSZB@]{4,})[.:]?$",
            options: [.caseInsensitive])
        let anchors = cluster.filter { word in
            tokenRx.firstMatch(in: word.text,
                               range: NSRange(word.text.startIndex..., in: word.text)) != nil
        }.map { $0.x + $0.w / 2 }.sorted()
        guard anchors.count >= 2 else { return [cluster] }

        var cuts: [(gap: Double, x: Double)] = []
        for i in 0..<(anchors.count - 1) {
            let gap = anchors[i + 1] - anchors[i]
            if gap > mh * 5 { cuts.append((gap, (anchors[i] + anchors[i + 1]) / 2)) }
        }
        for candidate in cuts.sorted(by: { $0.gap > $1.gap }) {
            let left = cluster.filter { $0.x + $0.w / 2 < candidate.x }
            let right = cluster.filter { $0.x + $0.w / 2 >= candidate.x }
            guard left.count >= 12, right.count >= 12,
                  shouldAcceptRefinedSplit([left, right]) else { continue }
            return splitSideBySideDocuments(left, medianHeight: mh, depth: depth + 1)
                 + splitSideBySideDocuments(right, medianHeight: mh, depth: depth + 1)
        }
        return [cluster]
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

                    // Formularele tipizate au frecvent corpul in stanga si blocul
                    // "CHITANTA / Serie / Numar / Data" in dreapta. XY-cut le
                    // separa, desi sunt acelasi document. Le reunim numai cand
                    // fragmentele sunt complementare: unul are titlul, celalalt
                    // are simultan "primit de la" si "suma", iar niciunul nu este bon.
                    let ta = groupLines(merged[i]).joined(separator: " ").uppercased()
                    let tb = groupLines(merged[j]).joined(separator: " ").uppercased()
                    let ra = NSRange(ta.startIndex..., in: ta)
                    let rb = NSRange(tb.startIndex..., in: tb)
                    let aTitle = chitantaTitleRx.firstMatch(in: ta, range: ra) != nil
                    let bTitle = chitantaTitleRx.firstMatch(in: tb, range: rb) != nil
                    let aBody = ta.contains("PRIMIT DE LA") && ta.contains("SUMA")
                    let bBody = tb.contains("PRIMIT DE LA") && tb.contains("SUMA")
                    let hasBon = (ta + " " + tb).range(
                        of: "BON\\s+FISCAL|TOTAL\\s*TVA|CASA\\s+DE\\s+MARCAT",
                        options: .regularExpression) != nil
                    let yInter = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    let minH = min(a.maxY - a.minY, b.maxY - b.minY)
                    let yOverlap = (yInter > 0 && minH > 0) ? yInter / minH : 0
                    let hGap = max(b.minX - a.maxX, a.minX - b.maxX, 0)
                    if !hasBon && ((aTitle && bBody) || (bTitle && aBody)),
                       yOverlap > 0.25, hGap < mh * 45 {
                        merged[i].append(contentsOf: merged[j])
                        merged.remove(at: j)
                        changed = true
                        break outer
                    }

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
        //  - liniile cu CUI prefixat RO merg ca ancora chiar cand eticheta e
        //    ilizibila (OCR: "Codl Identiticare Fiscala: R0…");
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

    /// A doua segmentare este acceptata numai daca FIECARE bucata este un
    /// document autonom, nu doar un antet sau un footer desprins de acelasi bon.
    /// Regula foloseste semantica documentului, nu numarul/pozitia bonurilor.
    static func shouldAcceptRefinedSplit(_ clusters: [[OCRBoxItem]]) -> Bool {
        guard clusters.count > 1 else { return false }
        return clusters.allSatisfy { cluster in
            let text = groupLines(cluster).joined(separator: " ").uppercased()
            let isChitanta = looksLikeSingleChitanta(cluster)
            if isChitanta {
                return text.contains("PRIMIT DE LA") && text.contains("SUMA")
            }
            let hasMerchantHeader = hasFiscalHeader(cluster)
            let hasFiscalBody = text.range(
                of: "BON\\s+FISCAL|(?<!SUB)\\bTOTAL\\b(?!\\s*TVA)",
                options: .regularExpression) != nil
            return hasMerchantHeader && hasFiscalBody
        }
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

    /// Fragmente mici pe care XY-cut le rupe din corp: sume (613.10), TVA,
    /// titlu chitanta. Fara asta, totalul Douglas dispare din cluster.
    private static let moneyTokenRx = try! NSRegularExpression(
        pattern: "\\b\\d{1,5}[.,]\\d{2}\\b")
    private static let amountContextRx = try! NSRegularExpression(
        pattern: "(?<!SUB)\\bTOTAL\\b|\\bTVA\\b|SUBTOTAL|SUMA\\s*TVA",
        options: [.caseInsensitive])

    static func isValuableFragment(_ part: [OCRBoxItem]) -> Bool {
        if part.isEmpty { return false }
        let text = groupLines(part).joined(separator: " ")
        let r = NSRange(text.startIndex..., in: text)
        if chitantaTitleRx.firstMatch(in: text, range: r) != nil { return true }
        if amountContextRx.firstMatch(in: text, range: r) != nil { return true }
        // Cel putin o suma monetara tipica de bon (nu un an / CUI)
        let moneyHits = moneyTokenRx.numberOfMatches(in: text, range: r)
        return moneyHits >= 1 && part.count >= 2
    }

    static func absorbOrphans(_ clusters: [[OCRBoxItem]],
                              medianHeight mh: Double) -> [[OCRBoxItem]] {
        var anchored: [[OCRBoxItem]] = []
        var orphans: [[OCRBoxItem]] = []
        for c in clusters {
            if hasFiscalHeader(c) { anchored.append(c) } else { orphans.append(c) }
        }
        guard !anchored.isEmpty else { return clusters }
        // Orfani = fara antet SAU fragmente pure de sume (TOTAL / 613.10) care
        // pot avea accidental un token "TOTAL" dar nu antet fiscal complet.
        var loose: [[OCRBoxItem]] = orphans
        var hosts = anchored
        // Reclasifica din anchored fragmentele care sunt DOAR sume (fara CUI/numar bon)
        var pureHosts: [[OCRBoxItem]] = []
        for a in hosts {
            let text = groupLines(a).joined(separator: " ").uppercased()
            let hasMerchant = merchantCuiHints(a).isEmpty == false
                || text.range(of: "SRL|S\\.A\\.|PFA|NUMAR\\s*BON|COD\\s*FISCAL",
                              options: .regularExpression) != nil
            if !hasMerchant && isValuableFragment(a) && a.count < 20 {
                loose.append(a)
            } else {
                pureHosts.append(a)
            }
        }
        hosts = pureHosts.isEmpty ? anchored : pureHosts
        for o in loose {
            let ob = bbox(o)
            var bestIdx = -1
            var bestTier = Int.max
            var bestDist = Double.greatestFiniteMagnitude
            let oText = groupLines(o).joined(separator: " ").uppercased()
            let oIsMoney = moneyTokenRx.firstMatch(
                in: oText, range: NSRange(oText.startIndex..., in: oText)) != nil
            for (i, a) in hosts.enumerated() {
                let ab = bbox(a)
                let inter = min(ob.maxX, ab.maxX) - max(ob.minX, ab.minX)
                let minw = min(ob.maxX - ob.minX, ab.maxX - ab.minX)
                let xov = (inter > 0 && minw > 0) ? inter / minw : 0
                let vgap = max(ab.minY - ob.maxY, ob.minY - ab.maxY, 0)
                let hgap = max(ab.minX - ob.maxX, ob.minX - ab.maxX, 0)
                // Sumele pe Douglas stau la dreapta (overlap Y mare, gap X mic)
                let yInter = min(ob.maxY, ab.maxY) - max(ob.minY, ab.minY)
                let minh = min(ob.maxY - ob.minY, ab.maxY - ab.minY)
                let yov = (yInter > 0 && minh > 0) ? yInter / minh : 0
                let tier: Int
                let dist: Double
                if xov > 0.3 {
                    tier = 0; dist = vgap
                } else if oIsMoney && yov > 0.15 && hgap < mh * 25 {
                    tier = 0; dist = hgap  // lipeste coloana de sume pe corp
                } else {
                    tier = 1; dist = (vgap * vgap + hgap * hgap).squareRoot()
                }
                if tier < bestTier || (tier == bestTier && dist < bestDist) {
                    bestTier = tier; bestDist = dist; bestIdx = i
                }
            }
            let maxDist = oIsMoney ? mh * 35 : mh * 20
            if bestIdx >= 0, bestDist <= maxDist {
                hosts[bestIdx].append(contentsOf: o)
            } else if o.count >= 12 {
                // Orfan mare: pastreaza-l ca document potential
                hosts.append(o)
            }
        }
        return hosts
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

    /// Elimina dublurile din re-OCR dublu (zona + full-page): acelasi text la
    /// pozitie aproape identica. Fara asta: "MAGISTRAL MAGISTRAL GAZ GAZ SRL SRL".
    static func dedupeWords(_ words: [OCRBoxItem]) -> [OCRBoxItem] {
        guard words.count > 1 else { return words }
        let sorted = words.sorted { a, b in
            let ca = a.y + a.h / 2, cb = b.y + b.h / 2
            return ca != cb ? ca < cb : a.x < b.x
        }
        var out: [OCRBoxItem] = []
        for w in sorted {
            let t = w.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let cx = w.x + w.w / 2, cy = w.y + w.h / 2
            let dup = out.contains { o in
                o.text.caseInsensitiveCompare(t) == .orderedSame
                    && abs((o.x + o.w / 2) - cx) < max(o.w, w.w, 8) * 0.55
                    && abs((o.y + o.h / 2) - cy) < max(o.h, w.h, 6) * 0.7
            }
            if !dup { out.append(w) }
        }
        return out
    }

    /// Colapseaza tokeni consecutivi identici pe linie ("TOTAL TOTAL" → "TOTAL").
    private static func collapseAdjacentDuplicates(_ tokens: [String]) -> [String] {
        var out: [String] = []
        for t in tokens {
            if let last = out.last, last.caseInsensitiveCompare(t) == .orderedSame { continue }
            out.append(t)
        }
        return out
    }

    static func linesWithY(_ words: [OCRBoxItem]) -> [(y: Double, text: String)] {
        guard !words.isEmpty else { return [] }
        let cleaned = dedupeWords(words)
        let hs = cleaned.map { $0.h }.sorted()
        let mh = max(hs[hs.count / 2], 4.0)
        let sorted = cleaned.sorted { a, b in
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
            let tokens = collapseAdjacentDuplicates(ws.sorted { $0.x < $1.x }.map { $0.text })
            return (y, tokens.joined(separator: " "))
        }
    }

    // MARK: - Helpers

    static func bbox(_ c: [OCRBoxItem]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (c.map { $0.x }.min() ?? 0, c.map { $0.y }.min() ?? 0,
         c.map { $0.x + $0.w }.max() ?? 0, c.map { $0.y + $0.h }.max() ?? 0)
    }
}
