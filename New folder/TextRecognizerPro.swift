//
//  TextRecognizerPro.swift
//  OcrServer
//
//  INLOCUIESTE TextRecognizerPlus.swift (scoate-l pe cel vechi din target).
//
//  Ce rezolva fata de versiunea Plus:
//   1. Bonuri cu orientari DIFERITE in aceeasi poza (cazul ROG GAZ, rotit 90°).
//      Versiunea veche alegea O SINGURA orientare globala pentru toata poza,
//      deci bonul rotit nu producea niciun cuvant si disparea complet.
//      Acum: detectie in toate cele 4 orientari, segmentare per orientare,
//      iar pe fiecare zona a pozei castiga orientarea care a citit cel mai
//      mult text (deduplicare pe IoU in spatiul pozei originale).
//   2. Rotire deterministica prin CGContext + formule de mapare inversa a
//      dreptunghiurilor in spatiul pozei originale (pentru debug overlay).
//   3. Respecta tag-ul EXIF al pozei (telefoanele salveaza des rotit + tag).
//   4. Pastreaza crop + normalizare contrast + re-OCR per bon din Plus.
//

import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO

/// Un bon detectat in poza.
struct ReceiptDetection {
    let turns: Int              // sferturi de rotatie CCW aplicate pozei de baza (0..3)
    let words: [OCRBoxItem]     // cuvintele bonului, in spatiul imaginii ROTITE
    let baseRect: CGRect        // bbox-ul bonului, in spatiul pozei ORIGINALE
    let score: Double           // nr. de caractere recunoscute (pentru dedup)
}

final class TextRecognizerPro {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Imagine de baza (aplica EXIF, limiteaza dimensiunea)

    func baseCGImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4600] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Detectia bonurilor in toate orientarile

    func detectReceipts(in base: CGImage) async -> [ReceiptDetection] {
        // 1. Probe rapid (.fast) in cele 4 orientari — decide unde merita .accurate
        var fastScores: [Int: Double] = [:]
        for t in 0...3 {
            fastScores[t] = await probeScore(Self.rotate(base, quarterTurnsCCW: t))
        }
        let maxScore = fastScores.values.max() ?? 0
        // prag mic intentionat: un singur bon rotit dintr-o poza cu 6 bonuri
        // aduce doar ~10-15% din caracterele orientarii dominante
        let selected = (0...3).filter { (fastScores[$0] ?? 0) > max(60, maxScore * 0.08) }

        // 2. OCR .accurate + segmentare, doar pe orientarile promitatoare
        var candidates: [ReceiptDetection] = []
        for t in selected {
            let img = Self.rotate(base, quarterTurnsCCW: t)
            let (words, W, H) = await wordBoxes(on: img)
            for seg in ReceiptSegmenterV2.segment(words) {
                let bb = Self.bbox(seg)
                let rectRot = CGRect(x: bb.minX, y: bb.minY,
                                     width: bb.maxX - bb.minX, height: bb.maxY - bb.minY)
                let rectBase = Self.mapRectToBase(rectRot, turns: t, rotatedW: W, rotatedH: H)
                let score = seg.reduce(0.0) { $0 + Double($1.text.count) }
                candidates.append(ReceiptDetection(turns: t, words: seg,
                                                   baseRect: rectBase, score: score))
            }
        }

        // 3. Dedup: pe aceeasi zona a pozei castiga orientarea cu scorul maxim.
        //    (Textul citit in orientarea gresita produce putine cuvinte => pierde.)
        var accepted: [ReceiptDetection] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            let overlaps = accepted.contains { Self.iou($0.baseRect, c.baseRect) > 0.30 }
            if !overlaps { accepted.append(c) }
        }

        // 4. Ordonare stabila: coloana (bucket de 400 px), apoi de sus in jos.
        //    ATENTIE: comparatorul vechi incalca strict weak ordering (crash posibil).
        return accepted.sorted { a, b in
            let ka = Int((a.baseRect.minX / 400).rounded(.down))
            let kb = Int((b.baseRect.minX / 400).rounded(.down))
            return ka != kb ? ka < kb : a.baseRect.minY < b.baseRect.minY
        }
    }

    private func probeScore(_ image: CGImage) async -> Double {
        var probe = RecognizeTextRequest()
        probe.recognitionLevel = .fast
        probe.usesLanguageCorrection = false
        let obs = (try? await probe.perform(on: image)) ?? []
        var s = 0.0
        for o in obs {
            if let c = o.topCandidates(1).first {
                s += Double(c.string.count) * Double(c.confidence)
            }
        }
        return s
    }

    // MARK: - OCR la nivel de cuvant (identic ca logica cu versiunea Plus)

    func wordBoxes(on image: CGImage) async -> (boxes: [OCRBoxItem], width: Int, height: Int) {
        let W = image.width
        let H = image.height

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // corectia "repara" gresit CUI-uri/coduri
        request.recognitionLanguages = [Locale.Language(identifier: "ro-RO"),
                                        Locale.Language(identifier: "en-US")]

        let observations = (try? await request.perform(on: image)) ?? []
        var items: [OCRBoxItem] = []
        items.reserveCapacity(observations.count * 6)

        for obs in observations {
            guard let best = obs.topCandidates(1).first else { continue }
            let str = best.string
            var searchStart = str.startIndex
            while searchStart < str.endIndex {
                while searchStart < str.endIndex, str[searchStart].isWhitespace {
                    searchStart = str.index(after: searchStart)
                }
                guard searchStart < str.endIndex else { break }
                var end = searchStart
                while end < str.endIndex, !str[end].isWhitespace {
                    end = str.index(after: end)
                }
                let range = searchStart..<end
                let word = String(str[range])
                searchStart = end

                guard let quad = try? best.boundingBox(for: range) else { continue }
                let corners = [quad.topLeft, quad.topRight, quad.bottomLeft, quad.bottomRight]
                let xs = corners.map { Double($0.x) * Double(W) }
                let ys = corners.map { (1.0 - Double($0.y)) * Double(H) }
                let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
                let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
                items.append(OCRBoxItem(text: word, x: minX, y: minY,
                                        w: maxX - minX, h: maxY - minY, rect: nil))
            }
        }
        return (items, W, H)
    }

    // MARK: - Crop per bon + enhance + re-OCR (in spatiul imaginii rotite)

    func cropAndReOCR(rotatedImage: CGImage,
                      clusterBoxes: [OCRBoxItem],
                      marginRatio: Double = 0.03) async -> [OCRBoxItem] {
        guard !clusterBoxes.isEmpty else { return [] }
        let minX = clusterBoxes.map { $0.x }.min()!
        let minY = clusterBoxes.map { $0.y }.min()!
        let maxX = clusterBoxes.map { $0.x + $0.w }.max()!
        let maxY = clusterBoxes.map { $0.y + $0.h }.max()!
        let mX = (maxX - minX) * marginRatio
        let mY = (maxY - minY) * marginRatio
        let cropRect = CGRect(x: max(0, minX - mX),
                              y: max(0, minY - mY),
                              width: min(Double(rotatedImage.width), maxX + mX) - max(0, minX - mX),
                              height: min(Double(rotatedImage.height), maxY + mY) - max(0, minY - mY))
        guard let crop = rotatedImage.cropping(to: cropRect) else { return clusterBoxes }

        let enhanced = enhanceForThermalPrint(crop)
        var (words, _, _) = await wordBoxes(on: enhanced)
        let scale = Double(enhanced.width) / Double(crop.width)   // upscale-ul 2x din enhance
        for i in words.indices {
            words[i] = OCRBoxItem(text: words[i].text,
                                  x: words[i].x / scale + cropRect.origin.x,
                                  y: words[i].y / scale + cropRect.origin.y,
                                  w: words[i].w / scale, h: words[i].h / scale, rect: nil)
        }
        // fallback: daca re-OCR-ul a iesit mai prost, pastreaza prima trecere
        return words.count >= clusterBoxes.count / 2 ? words : clusterBoxes
    }

    private func enhanceForThermalPrint(_ image: CGImage) -> CGImage {
        var ci = CIImage(cgImage: image)
        let mono = CIFilter.colorControls()
        mono.inputImage = ci
        mono.saturation = 0
        mono.contrast = 1.35
        mono.brightness = 0.02
        ci = mono.outputImage ?? ci
        let sharp = CIFilter.sharpenLuminance()
        sharp.inputImage = ci
        sharp.sharpness = 0.4
        ci = sharp.outputImage ?? ci
        if image.width < 900 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        }
        return ciContext.createCGImage(ci, from: ci.extent) ?? image
    }

    // MARK: - Rotatie deterministica + mapari de coordonate

    /// Rotire cu `turns` sferturi in sens ANTIORAR (cum se vede pe ecran).
    static func rotate(_ img: CGImage, quarterTurnsCCW turns: Int) -> CGImage {
        let t = ((turns % 4) + 4) % 4
        guard t != 0 else { return img }
        let w = img.width, h = img.height
        let swap = (t % 2 == 1)
        let nw = swap ? h : w
        let nh = swap ? w : h
        guard let ctx = CGContext(data: nil, width: nw, height: nh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: CGFloat(t) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                                 width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? img
    }

    /// Mapare inversa: dreptunghi din spatiul imaginii rotite -> spatiul pozei originale.
    /// (Coordonate de afisare: origine sus-stanga, y in jos.)
    static func mapRectToBase(_ r: CGRect, turns: Int, rotatedW: Int, rotatedH: Int) -> CGRect {
        let t = ((turns % 4) + 4) % 4
        let rw = CGFloat(rotatedW), rh = CGFloat(rotatedH)
        switch t {
        case 0:
            return r
        case 1: // baza a fost rotita 90° CCW; latimea bazei = rh
            return CGRect(x: rh - (r.minY + r.height), y: r.minX,
                          width: r.height, height: r.width)
        case 2:
            return CGRect(x: rw - (r.minX + r.width), y: rh - (r.minY + r.height),
                          width: r.width, height: r.height)
        default: // 3 (= 90° CW); inaltimea bazei = rw
            return CGRect(x: r.minY, y: rw - (r.minX + r.width),
                          width: r.height, height: r.width)
        }
    }

    /// Muta box-urile de cuvinte in spatiul pozei originale (pentru debug overlay).
    static func mapWordsToBase(_ words: [OCRBoxItem], turns: Int,
                               rotatedW: Int, rotatedH: Int) -> [OCRBoxItem] {
        guard turns % 4 != 0 else { return words }
        return words.map { w in
            let r = mapRectToBase(CGRect(x: w.x, y: w.y, width: w.w, height: w.h),
                                  turns: turns, rotatedW: rotatedW, rotatedH: rotatedH)
            return OCRBoxItem(text: w.text, x: Double(r.minX), y: Double(r.minY),
                              w: Double(r.width), h: Double(r.height), rect: nil)
        }
    }

    // MARK: - Helpers

    static func bbox(_ c: [OCRBoxItem]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (c.map { $0.x }.min() ?? 0, c.map { $0.y }.min() ?? 0,
         c.map { $0.x + $0.w }.max() ?? 0, c.map { $0.y + $0.h }.max() ?? 0)
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let ia = Double(inter.width * inter.height)
        let ua = Double(a.width * a.height) + Double(b.width * b.height) - ia
        return ua > 0 ? ia / ua : 0
    }
}
