//
//  TextRecognizer.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/1.
//

import Foundation
import Vision
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

class TextRecognizer {
    let recognitionLevel : RecognizeTextRequest.RecognitionLevel
    let usesLanguageCorrection : Bool
    let automaticallyDetectsLanguage : Bool
    
    init(recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate,
         usesLanguageCorrection: Bool = true,
         automaticallyDetectsLanguage: Bool = true) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    }
    
    func getOcrResult(data: Data) async -> OCRResult? {
        if let pdfDoc = PDFDocument(data: data), pdfDoc.pageCount > 0 {
            return await processPDF(pdfDoc)
        }
        return await processImage(data: data)
    }
    
    private func processPDF(_ pdfDoc: PDFDocument) async -> OCRResult? {
        var fullText = ""
        for i in 0..<pdfDoc.pageCount {
            if let page = pdfDoc.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }
        
        fullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Daca textul nativ e suficient de lung, e factura electronica (SmartBill etc.)
        if fullText.count > 50 {
            let lines = fullText.components(separatedBy: "\n").filter { !$0.isEmpty }
            var items: [OCRBoxItem] = []
            for (idx, line) in lines.enumerated() {
                items.append(OCRBoxItem(text: line, x: 0, y: Double(idx * 20), w: 500, h: 20, rect: nil))
            }
            return OCRResult(text: fullText, image_width: 800, image_height: 1000, boxes: items)
        }
        
        // Daca e prea scurt (PDF scanat tip poza), rasterizam prima pagina
        #if canImport(UIKit)
        if let page = pdfDoc.page(at: 0) {
            let pageRect = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: pageRect.size)
            let img = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(pageRect)
                ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
                ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            if let imgData = img.jpegData(compressionQuality: 0.8) {
                return await processImage(data: imgData)
            }
        }
        #endif
        
        return nil
    }

    private func processImage(data: Data) async -> OCRResult? {
        // 嘗試取影像像素大小
        guard let (W, H) = Self.imagePixelSize(from: data) else {
            return nil
        }
        
        var request = RecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        
        let observations = (try? await request.perform(on: data)) ?? []
        
        var lines: [String] = []
        var items: [OCRBoxItem] = []
        
        func toPixel(_ p: NormalizedPoint) -> (Double, Double) {
            let x = Double(p.x * Double(W))
            let y = Double((1 - p.y) * Double(H))
            return (x, y)
        }
        
        for obs in observations {
            guard let best = obs.topCandidates(1).first else { continue }
            let text = best.string
            lines.append(text)
            
            // 四個角轉成像素座標（左上為原點）
            let corners = [
                CGPoint(x: obs.topLeft.x     * CGFloat(W), y: (1 - obs.topLeft.y)     * CGFloat(H)),
                CGPoint(x: obs.topRight.x    * CGFloat(W), y: (1 - obs.topRight.y)    * CGFloat(H)),
                CGPoint(x: obs.bottomRight.x * CGFloat(W), y: (1 - obs.bottomRight.y) * CGFloat(H)),
                CGPoint(x: obs.bottomLeft.x  * CGFloat(W), y: (1 - obs.bottomLeft.y)  * CGFloat(H))
            ]
            
            // 取最小外接矩形
            let minX = corners.map { $0.x }.min() ?? 0
            let maxX = corners.map { $0.x }.max() ?? 0
            let minY = corners.map { $0.y }.min() ?? 0
            let maxY = corners.map { $0.y }.max() ?? 0
            
            let rectX = Double(minX)
            let rectY = Double(minY)
            let rectW = Double(maxX - minX)
            let rectH = Double(maxY - minY)
            
            // 文字角度
            var rectItem: OCRRectItem? = nil
            if let rect = best.boundingBox(for: best.string.startIndex..<best.string.endIndex) {
                let tl = toPixel(rect.topLeft)
                let tr = toPixel(rect.topRight)
                let bl = toPixel(rect.bottomLeft)
                let br = toPixel(rect.bottomRight)

                rectItem = OCRRectItem(
                    topLeft_x: tl.0, topLeft_y: tl.1,
                    topRight_x: tr.0, topRight_y: tr.1,
                    bottomLeft_x: bl.0, bottomLeft_y: bl.1,
                    bottomRight_x: br.0, bottomRight_y: br.1
                )
            }
            
            items.append(OCRBoxItem(text: text, x: rectX, y: rectY, w: rectW, h: rectH, rect: rectItem))
        }
        
        return OCRResult(
            text: lines.joined(separator: "\n"),
            image_width: W,
            image_height: H,
            boxes: items
        )
    }
    
    private static func imagePixelSize(from data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return nil
        }
        return (w, h)
    }
}
