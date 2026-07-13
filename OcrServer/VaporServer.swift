//
//  VaporServer.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Vapor
import Vision
import PDFKit

public struct OCRRectItem: Content {
    let topLeft_x: Double
    let topLeft_y: Double
    let topRight_x: Double
    let topRight_y: Double
    let bottomLeft_x: Double
    let bottomLeft_y: Double
    let bottomRight_x: Double
    let bottomRight_y: Double
}

public struct OCRBoxItem: Content {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let rect: OCRRectItem?
}

struct OCRResult: Content {
    let text: String
    let image_width: Int
    let image_height: Int
    let boxes: [OCRBoxItem]
}

struct DocOCRResult: Content {
    let success: Bool
    let message: String
    let ocr_text: String
}

struct UploadResponse: Content {
    let success: Bool
    let message: String
    let ocr_result: String
    let image_width: Int
    let image_height: Int
    let ocr_boxes: [OCRBoxItem]
    var accounting_data: AccountingResult? = nil
    var accounting_data_array: [AccountingResult]? = nil
    var receipts: [ReceiptResult]? = nil
    var chitante: [ChitantaResult]? = nil
}

actor VaporServer {
    private var app: Application?
    private var runTask: Task<Void, Never>?
    
    // 自動重啟設定
    private var shouldAutoRestart = true
    
    // 當伺服器停止時發通知
    private var onStopped: (@Sendable () -> Void)?

    let host: String = "0.0.0.0"
    let environment: Environment = .production
    
    // 可由外部設置
    var port: Int = 8000

    // OCR 參數
    var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate
    var usesLanguageCorrection: Bool = true
    var automaticallyDetectsLanguage: Bool = true

    private(set) var isRunning: Bool = false

    // MARK: - Public API

    // 設定停止時回呼
    func setOnStopped(_ handler: @escaping @Sendable () -> Void) {
        self.onStopped = handler
    }
    
    // 開關自動重啟
    func setAutoRestart(_ enabled: Bool) {
        self.shouldAutoRestart = enabled
    }

    func start() async throws {
        guard runTask == nil else { return } // 已在跑就不重複啟動

        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = host
        app.http.server.configuration.port = port

        let corsConfiguration = CORSMiddleware.Configuration(
            allowedOrigin: .all,
            allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
        )
        let cors = CORSMiddleware(configuration: corsConfiguration)
        app.middleware.use(cors, at: .beginning)
        
        let publicDir = Bundle.main.resourcePath ?? ""
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))

        try routes(app)

        self.app = app
        isRunning = true

        // 用 Task 背景執行事件迴圈
        runTask = Task { [weak app, weak self] in
            guard let self = self else { return }
            var hadError = false
            do {
                try await app?.execute()
            } catch {
                hadError = true
            }
            
            // 通知外界「已停止」
            if let cb = await self.onStopped { cb() }
            
            // 依設定自動重啟
            if await self.shouldAutoRestart && hadError {
                await self.cleanupAfterStop()
                NotificationCenter.default.post(
                    name: .vaporServerShouldRestart,
                    object: nil,
                    userInfo: ["reason": "crash"]
                )
            }
        }
    }

    func stop() async {
        guard let app = app else { return }
        try? await app.asyncShutdown()   // 非同步關閉
        self.cleanupAfterStop()
    }

    func restart() async throws {
        await stop()
        try await start()
    }
    
    func running() -> Bool { isRunning }
    
    func configure(
        port: Int? = nil,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel? = nil,
        usesLanguageCorrection: Bool? = nil,
        automaticallyDetectsLanguage: Bool? = nil,
    ) {
        if let v = port { self.port = v }
        if let v = recognitionLevel { self.recognitionLevel = v }
        if let v = usesLanguageCorrection { self.usesLanguageCorrection = v }
        if let v = automaticallyDetectsLanguage { self.automaticallyDetectsLanguage = v }
    }
    
    // MARK: - Cleanup After Stop
    
    private func cleanupAfterStop() {
        //runTask?.cancel()
        runTask = nil
        app = nil
        isRunning = false
    }

    // MARK: - Routes

    private func routes(_ app: Application) throws {
        // GET /ping
        app.get("ping") { req async throws -> Response in
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: .ok, headers: headers, body: .init(string: "{\"status\":\"ok\"}"))
        }
        
        let serveWebClient: @Sendable (Request) throws -> Response = { req in
            guard let url = Bundle.main.url(forResource: "webclient_index", withExtension: "html"),
                  let html = try? String(contentsOf: url, encoding: .utf8) else {
                throw Abort(.notFound, reason: "webclient_index.html lipseste din bundle — verifica Copy Bundle Resources")
            }
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return Response(status: .ok, headers: headers, body: .init(string: html))
        }
        
        app.get(use: serveWebClient)
        app.get("webclient_index.html", use: serveWebClient)
        // GET /debug_boxes - returneaza ultimele box-uri OCR procesate (pentru debug)
        app.get("debug_boxes") { req -> Response in
            let res = Response(status: .ok)
            res.headers.contentType = .json
            if let data = AccountingOrchestrator.shared.lastBoxesJson {
                res.body = .init(data: data)
            } else {
                res.body = .init(string: "{\"message\": \"No boxes processed yet. Upload an image first.\"}")
            }
            return res
        }

        // POST /upload（限制收集本文大小，可自行調整）
        app.on(.POST, "upload", body: .collect(maxSize: "100mb")) { [weak self] req async throws -> Response in
            guard let self else { throw Abort(.internalServerError) }

            struct Upload: Content { 
                var file: File 
                var buyer_cui: String?
                var processing_mode: String?
                var doc_type: String?
            }

            let upload: Upload
            do {
                upload = try req.content.decode(Upload.self)
            } catch {
                return try Self.jsonResponse(
                    .badRequest,
                    UploadResponse(
                        success: false,
                        message: "Missing or empty 'file' part",
                        ocr_result: "",
                        image_width: 0,
                        image_height: 0,
                        ocr_boxes: []
                    )
                )
            }

            guard upload.file.data.readableBytes > 0 else {
                return try Self.jsonResponse(
                    .badRequest,
                    UploadResponse(
                        success: false,
                        message: "Missing or empty 'file' part",
                        ocr_result: "",
                        image_width: 0,
                        image_height: 0,
                        ocr_boxes: []
                    )
                )
            }

            // 取得 actor 內的參數（需 await）
            let recognitionLevel = await self.recognitionLevel
            let usesLanguageCorrection = await self.usesLanguageCorrection
            let automaticallyDetectsLanguage = await self.automaticallyDetectsLanguage

            // ByteBuffer -> Data
            let data = Self.byteBufferToData(upload.file.data)

            // OCR
            let textRecognizer = TextRecognizer(
                recognitionLevel: recognitionLevel,
                usesLanguageCorrection: usesLanguageCorrection,
                automaticallyDetectsLanguage: automaticallyDetectsLanguage
            )

            let accept = (req.headers.first(name: .accept) ?? "").lowercased()
            
            var accountingData: AccountingResult? = nil
            var accountingDataArray: [AccountingResult] = []
            var fullText = ""
            var W = 0
            var H = 0
            var allBoxesOut: [OCRBoxItem] = []
            var receiptsList: [ReceiptResult] = []
            var chitanteList: [ChitantaResult] = []
            
            if PDFDocument(data: data) != nil {
                let result = await textRecognizer.getOcrResult(data: data)
                if let boxes = result?.boxes, !boxes.isEmpty {
                    print("===== OCR DEBUG =====")
                    print("Total OCR boxes: \(boxes.count)")
                    
                    // Print all boxes that contain CUI-related keywords
                    for box in boxes {
                        let upper = box.text.uppercased()
                        if upper.contains("CIF") || upper.contains("CUI") || upper.contains("FISCAL") || upper.contains("RO") {
                            print("  CUI-box: '\(box.text)' at x=\(Int(box.x)) y=\(Int(box.y)) w=\(Int(box.w)) h=\(Int(box.h))")
                        }
                        if upper.contains("TOTAL") {
                            print("  TOTAL-box: '\(box.text)' at x=\(Int(box.x)) y=\(Int(box.y))")
                        }
                        if upper.contains("TVA") {
                            print("  TVA-box: '\(box.text)' at x=\(Int(box.x)) y=\(Int(box.y))")
                        }
                    }
                    
                    let clusters = AccountingOrchestrator.shared.clusterBoxes(boxes)
                    print("Clusters found: \(clusters.count)")
                    for (i, cluster) in clusters.enumerated() {
                        print("  Cluster \(i): \(cluster.count) boxes")
                        let clusterText = cluster.prefix(5).map { "'\($0.text)'" }.joined(separator: ", ")
                        print("    First boxes: \(clusterText)")
                    }
                    
                    for cluster in clusters {
                        let clusterResults = await AccountingOrchestrator.shared.processOcrResult(boxes: cluster, buyerCui: upload.buyer_cui)
                        print("  -> Produced \(clusterResults.count) results: CUI=\(clusterResults.first?.cui ?? "nil"), Total=\(clusterResults.first?.totalAmount ?? 0), TVA=\(clusterResults.first?.vatAmount ?? 0)")
                        accountingDataArray.append(contentsOf: clusterResults)
                    }
                    
                    print("Total accounting results: \(accountingDataArray.count)")
                    print("===== END DEBUG =====")
                    
                    // Pentru compatibilitate backward, primul element e in accountingData
                    accountingData = accountingDataArray.first
                }
                fullText = result?.text ?? ""
                W = result?.image_width ?? 0
                H = result?.image_height ?? 0
                allBoxesOut = result?.boxes ?? []
            } else {
                let pro = TextRecognizerPro()
                
                // --- 1. Imaginea de baza (aplica EXIF-ul pozei)
                guard let base = pro.baseCGImage(from: data) else {
                    return try Self.jsonResponse(.internalServerError, UploadResponse(
                        success: false, message: "Could not decode image",
                        ocr_result: "", image_width: 0, image_height: 0, ocr_boxes: []))
                }
                
                W = base.width
                H = base.height
                
                // --- 2. Detectia bonurilor IN TOATE ORIENTARILE (rezolva bonul rotit 90°)
                let detections = await pro.detectReceipts(in: base)
                print("Bonuri detectate: \(detections.count)")
                
                // cache pentru imaginile rotite (o rotatie per orientare folosita)
                var rotatedCache: [Int: CGImage] = [0: base]
                func rotatedImage(_ turns: Int) -> CGImage {
                    if let img = rotatedCache[turns] { return img }
                    let img = TextRecognizerPro.rotate(base, quarterTurnsCCW: turns)
                    rotatedCache[turns] = img
                    return img
                }
                
                // --- 3. Per bon: crop + contrast + re-OCR curat -> extractie
                receiptsList = []
                chitanteList = []
                
                let myCui = upload.buyer_cui ?? "30630040" // CUI-ul firmei tale (config / camp in upload)
                // selectorul din pagina: "auto" | "bon" | "chitanta" (doc_type = clientul nou, processing_mode = cel vechi)
                let mode = (upload.doc_type ?? upload.processing_mode ?? "auto").lowercased()
                
                for (i, det) in detections.enumerated() {
                    let rotImg = rotatedImage(det.turns)
                    let clean = await pro.cropAndReOCR(rotatedImage: rotImg, clusterBoxes: det.words)
                    let rawLines = ReceiptSegmenterV2.groupLines(clean)
                    
                    let autoIsChitanta = ChitantaExtractor.looksLikeChitanta(rawLines.joined(separator: "\n"))
                    let treatAsChitanta: Bool
                    switch mode {
                    case "chitanta": treatAsChitanta = true
                    case "bon":      treatAsChitanta = false
                    default:         treatAsChitanta = autoIsChitanta
                    }
                    if treatAsChitanta {
                        let hwWords = await pro.handwritingPass(on: rotImg)
                        let hwLines = ReceiptSegmenterV2.groupLines(hwWords)
                        var ch = ChitantaExtractor.extract(linesText: hwLines,
                                                           linesDigits: rawLines,
                                                           myCui: myCui)
                        // We map the clean words back to base image space for debug overlay
                        allBoxesOut.append(contentsOf: TextRecognizerPro.mapWordsToBase(
                            clean, turns: det.turns, rotatedW: rotImg.width, rotatedH: rotImg.height))
                        chitanteList.append(ch)
                    } else {
                        var r = ReceiptExtractor.extract(lines: rawLines, index: i, buyerCuiHint: upload.buyer_cui)
                        r.orientation = det.turns
                        r.bboxX = Double(det.baseRect.minX)
                        r.bboxY = Double(det.baseRect.minY)
                        r.bboxW = Double(det.baseRect.width)
                        r.bboxH = Double(det.baseRect.height)
                        // We map the clean words back to base image space for debug overlay
                        allBoxesOut.append(contentsOf: TextRecognizerPro.mapWordsToBase(
                            clean, turns: det.turns, rotatedW: rotImg.width, rotatedH: rotImg.height))
                        receiptsList.append(r)
                    }
                }
                
                // --- 4. UN SINGUR batch ANAF v9 pentru toate CUI-urile din poza
                //        (limita ANAF: 1 request/secunda -> nu apela per bon!)
                var allCandidates: [String] = []
                for r in receiptsList {
                    allCandidates.append(contentsOf: r.anafCandidates)
                    if let b = r.buyerCui, RoCUI.isValid(b) { allCandidates.append(b) }
                }
                for ch in chitanteList {
                    allCandidates.append(contentsOf: ch.anafCandidatesEmitent)
                    if let p = ch.platitorCui, RoCUI.isValid(p) { allCandidates.append(p) }
                }
                
                let anafInfo = await AnafClient.shared.verifyBatch(allCandidates)
                
                // --- 5. Dubla validare per bon: checksum + potrivire de denumire ANAF
                for i in receiptsList.indices {
                    let header = receiptsList[i].merchantNameOCR ?? ""
                    let res = AnafResolver.resolve(candidates: receiptsList[i].anafCandidates,
                                                   checksumWasValid: receiptsList[i].cuiChecksumValid,
                                                   ocrHeader: header,
                                                   anaf: anafInfo)
                    receiptsList[i].anaf.checked = !receiptsList[i].anafCandidates.isEmpty
                    receiptsList[i].anaf.status = res.status
                    receiptsList[i].anaf.nameScore = res.score
                    
                    if let comp = res.company {
                        receiptsList[i].cui = res.cui
                        receiptsList[i].anaf.found = true
                        receiptsList[i].anaf.denumire = comp.denumire
                        receiptsList[i].anaf.adresa = comp.adresa
                        receiptsList[i].anaf.scpTVA = comp.scpTVA
                        if comp.statusInactiv == true {
                            receiptsList[i].warnings.append("ATENTIE: firma figureaza INACTIVA la ANAF — TVA nedeductibila (art. 11 CF).")
                        }
                        if comp.scpTVA == false {
                            receiptsList[i].warnings.append("Firma NU e platitoare de TVA la data interogarii — verifica deducerea.")
                        }
                    } else if res.status == "cui_incert_necesita_verificare" || res.status == "cui_negasit_anaf" {
                        receiptsList[i].warnings.append("CUI neconfirmat de ANAF — necesita verificare manuala.")
                    }
                    
                    // numele cumparatorului, daca CUI-ul lui a fost si el verificat
                    if let b = receiptsList[i].buyerCui, let comp = anafInfo[b] {
                        receiptsList[i].buyerName = comp.denumire ?? receiptsList[i].buyerName
                    }
                }
                
                for i in chitanteList.indices {
                    let res = AnafResolver.resolve(candidates: chitanteList[i].anafCandidatesEmitent,
                                                   checksumWasValid: chitanteList[i].emitentCuiValid,
                                                   ocrHeader: chitanteList[i].emitentNume ?? "",
                                                   anaf: anafInfo)
                    chitanteList[i].emitentAnaf.status = res.status
                    chitanteList[i].emitentAnaf.nameScore = res.score
                    if let comp = res.company {
                        chitanteList[i].emitentCui = res.cui
                        chitanteList[i].emitentAnaf.found = true
                        chitanteList[i].emitentAnaf.denumire = comp.denumire
                        chitanteList[i].emitentAnaf.adresa = comp.adresa
                        chitanteList[i].emitentAnaf.scpTVA = comp.scpTVA
                    }
                    if let p = chitanteList[i].platitorCui, let comp = anafInfo[p] {
                        chitanteList[i].platitorAnaf.found = true
                        chitanteList[i].platitorAnaf.denumire = comp.denumire
                        chitanteList[i].platitorAnaf.status = "confirmat_anaf"
                        // dubla validare si pe nume, daca "Am primit de la" a fost citit:
                        if let nume = chitanteList[i].platitorNume {
                            chitanteList[i].platitorAnaf.nameScore =
                                AnafClient.nameMatchScore(anafName: comp.denumire ?? "", ocrHeader: nume)
                        }
                    }
                }
                
                fullText = receiptsList.map { $0.rawText }.joined(separator: "\n\n---\n\n")
                if !chitanteList.isEmpty {
                    fullText += "\n\n=== CHITANTE ===\n\n" + chitanteList.map { $0.rawText }.joined(separator: "\n\n---\n\n")
                }
                
                // --- 6. Populare pentru compatibilitate backward (pipeline-ul din table-ul vechi)
                for r in receiptsList {
                    var acc = AccountingResult()
                    acc.documentType = "Bon Fiscal"
                    acc.documentTypeRequiresVerification = false
                    acc.documentNumber = r.bonNumber
                    acc.documentDate = r.date
                    acc.cui = r.cui
                    acc.cuiRequiresVerification = r.warnings.contains { $0.contains("CUI") } || !r.cuiChecksumValid
                    acc.companyName = r.anaf.found ? r.anaf.denumire : r.merchantNameOCR
                    acc.companyAddress = r.anaf.adresa
                    acc.companyIsVatPayer = r.anaf.scpTVA
                    acc.totalAmount = r.total
                    acc.totalRequiresVerification = !r.mathVerified
                    acc.vatAmount = r.vatLines.first?.amount
                    acc.vatRequiresVerification = !r.mathVerified
                    acc.vatPercentages = r.vatLines.first.map { String($0.rate) }
                    if let base = r.vatLines.first?.base {
                        acc.baseAmount = base
                    } else if let total = r.total, let vat = r.vatLines.first?.amount {
                        acc.baseAmount = total - vat
                    } else {
                        acc.baseAmount = r.total
                    }
                    acc.suggestedAccount = r.suggestedAccount
                    acc.fiscalWarnings = r.warnings
                    acc.anafCandidates = r.anafCandidates
                    accountingDataArray.append(acc)
                }
                
                for ch in chitanteList {
                    var acc = AccountingResult()
                    acc.documentType = "Chitanță de mână"
                    acc.documentTypeRequiresVerification = false
                    acc.documentSeries = ch.serie
                    acc.documentNumber = ch.numar
                    acc.documentDate = ch.date
                    acc.cui = ch.emitentCui
                    acc.cuiRequiresVerification = !ch.emitentCuiValid
                    acc.companyName = ch.emitentAnaf.found ? ch.emitentAnaf.denumire : ch.emitentNume
                    acc.companyAddress = ch.emitentAnaf.adresa
                    acc.companyIsVatPayer = ch.emitentAnaf.scpTVA
                    acc.totalAmount = ch.suma
                    acc.totalRequiresVerification = !ch.sumaConfirmata
                    acc.vatAmount = 0
                    acc.vatRequiresVerification = false
                    acc.vatPercentages = "-"
                    acc.baseAmount = ch.suma
                    acc.suggestedAccount = ch.suggestedAccount
                    acc.fiscalWarnings = ch.warnings
                    acc.anafCandidates = ch.anafCandidatesEmitent
                    accountingDataArray.append(acc)
                }
                
                accountingData = accountingDataArray.first
                
                // === STOCARE PENTRU /debug_boxes ===
                do {
                    struct BoxDump: Codable {
                        let text: String; let x: Double; let y: Double; let w: Double; let h: Double
                    }
                    let dumpBoxes = allBoxesOut.map { BoxDump(text: $0.text, x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let jsonData = try encoder.encode(dumpBoxes)
                    AccountingOrchestrator.shared.lastBoxesJson = jsonData
                } catch {}
            }
            
            if accept.contains("application/json") {
                return try Self.jsonResponse(
                    .ok,
                    UploadResponse(
                        success: true,
                        message: (receiptsList.isEmpty && chitanteList.isEmpty)
                            ? "File uploaded successfully (pipeline v2: 0 documente detectate)"
                            : "\(receiptsList.count) bonuri, \(chitanteList.count) chitante detectate",
                        ocr_result: fullText,
                        image_width: W,
                        image_height: H,
                        ocr_boxes: allBoxesOut,
                        accounting_data: accountingData,
                        accounting_data_array: accountingDataArray,
                        receipts: receiptsList,
                        chitante: chitanteList
                    )
                )
            } else {
                let escaped = Self.htmlEscape(fullText)
                let html = """
                <!doctype html>
                <html>
                <head>
                    <meta charset="utf-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <title>OCR Server</title>
                </head>
                <body>
                    <h2>OCR Result:</h2>
                    <pre>\(escaped)</pre>
                </body>
                </html>
                """
                return Self.htmlResponse(html)
            }
        }
        
        // POST /docOCR（限制收集本文大小，可自行調整）
        app.on(.POST, "docOCR", body: .collect(maxSize: "100mb")) { [weak self] req async throws -> Response in
            if #unavailable(iOS 26) {
                // iOS 26 以下
                return try Self.jsonResponse(
                    .ok,
                    DocOCRResult(
                        success: false,
                        message: "This API is only supported on iOS 26 and later",
                        ocr_text: ""
                    )
                )
            }
            
            guard let self else { throw Abort(.internalServerError) }

            struct Upload: Content { var file: File }

            let upload: Upload
            do {
                upload = try req.content.decode(Upload.self)
            } catch {
                return try Self.jsonResponse(
                    .badRequest,
                    DocOCRResult(
                        success: false,
                        message: "Missing or empty 'file' part",
                        ocr_text: ""
                    )
                )
            }

            guard upload.file.data.readableBytes > 0 else {
                return try Self.jsonResponse(
                    .badRequest,
                    DocOCRResult(
                        success: false,
                        message: "Missing or empty 'file' part",
                        ocr_text: ""
                    )
                )
            }

            // 取得 actor 內的參數（需 await）
            _ = await self.usesLanguageCorrection
            _ = await self.automaticallyDetectsLanguage

            // ByteBuffer -> Data
            let data = Self.byteBufferToData(upload.file.data)

            let accept = (req.headers.first(name: .accept) ?? "").lowercased()
            
            // OCR
            var resultText : String? = nil
            // DocRecognizer is currently unsupported on this SDK version.
            if resultText == nil && accept.contains("application/json") {
                return try Self.jsonResponse(.internalServerError, DocOCRResult(success: false,
                                                                                message: "OCR failed",
                                                                                ocr_text: ""))
            }
            
            if accept.contains("application/json") {
                return try Self.jsonResponse(
                    .ok,
                    DocOCRResult(
                        success: true,
                        message: "OCR completed successfully",
                        ocr_text: resultText ?? ""
                    )
                )
            } else {
                let escaped = Self.htmlEscape(resultText ?? "")
                let html = """
                <!doctype html>
                <html>
                <head>
                    <meta charset="utf-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <title>OCR Server</title>
                    <style>
                        pre {
                            width: 100%;
                            max-width: 100%;
                            box-sizing: border-box;
                            white-space: pre-wrap;
                            word-wrap: break-word;
                            overflow-wrap: break-word;
                        }
                    </style>
                </head>
                <body>
                    <h2>OCR Result:</h2>
                    <hr>
                    <pre>\(escaped)</pre>
                </body>
                </html>
                """
                return Self.htmlResponse(html)
            }
        }
    }

    // MARK: - Helpers

    private static func byteBufferToData(_ buffer: ByteBuffer) -> Data {
        var tmp = buffer
        if let bytes = tmp.readBytes(length: tmp.readableBytes) {
            return Data(bytes)
        }
        return Data()
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func htmlResponse(_ html: String, status: HTTPResponseStatus = .ok) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: status, headers: headers, body: .init(string: html))
    }

    private static func jsonResponse<T: Content>(_ status: HTTPResponseStatus, _ payload: T) throws -> Response {
        let res = Response(status: status)
        try res.content.encode(payload, as: .json)
        return res
    }
}

extension Notification.Name {
    static let vaporServerShouldRestart = Notification.Name("vaporServerShouldRestart")
}

// MARK: - Accounting Extraction (Contabilitate)

public struct VatBreakdown: Content {
    public var percentage: String
    public var vatAmount: Double
    public var baseAmount: Double
}

public struct AccountingResult: Content {
    public var documentType: String?
    public var documentTypeRequiresVerification: Bool = true
    
    public var documentSeries: String?
    public var documentNumber: String?
    public var documentDate: String?
    
    public var cui: String?
    public var cuiRequiresVerification: Bool = true
    public var companyName: String?
    public var companyAddress: String?
    public var companyIsVatPayer: Bool?
    
    public var totalAmount: Double?
    public var totalRequiresVerification: Bool = true
    
    public var vatAmount: Double?
    public var vatRequiresVerification: Bool = true
    
    public var vatPercentages: String?
    
    public var baseAmount: Double?
    
    public var vatBreakdowns: [VatBreakdown]?
    public var anafCandidates: [String]?
    
    public var fiscalWarnings: [String] = []
    
    public var suggestedAccount: String?
    
    public var globalRequiresManualVerification: Bool {
        return documentTypeRequiresVerification || cuiRequiresVerification || totalRequiresVerification || vatRequiresVerification || !fiscalWarnings.isEmpty
    }
}

protocol AccountingAgent {
    func process(textBlocks: [String], boxes: [OCRBoxItem], result: inout AccountingResult) async
}

class DocumentClassificationAgent: AccountingAgent {
    func process(textBlocks: [String], boxes: [OCRBoxItem], result: inout AccountingResult) async {
        let fullText = textBlocks.joined(separator: " ").uppercased()
        
        let hasPOS = fullText.contains("TERMINAL ID") || fullText.contains("PIN VERIFICAT") || fullText.contains("TRANZACTIE ACCEPTATA") || fullText.contains("TRANZACTIE APROBATA") || fullText.contains("POS")
        
        if fullText.contains("FACTURA") || fullText.contains("INVOICE") {
            result.documentType = "Factură"
            result.documentTypeRequiresVerification = false
        } else if fullText.contains("BON FISCAL") || fullText.contains("CASA DE MARCAT") || fullText.contains("BF.") || fullText.contains("BF ") {
            result.documentType = "Bon Fiscal"
            result.documentTypeRequiresVerification = false
        } else if hasPOS {
            result.documentType = "Chitanță POS"
            result.documentTypeRequiresVerification = false
        } else if fullText.contains("CHITANTA") {
            result.documentType = "Chitanță de mână"
            result.documentTypeRequiresVerification = false
        } else if fullText.contains("BENZINA") || fullText.contains("MOTORINA") || fullText.contains("DIESEL") {
            result.documentType = "Fișă Combustibil"
            result.documentTypeRequiresVerification = false
        } else {
            result.documentType = "Necunoscut"
            result.documentTypeRequiresVerification = true
        }
    }
}

class DocumentDetailsAgent: AccountingAgent {
    func process(textBlocks: [String], boxes: [OCRBoxItem], result: inout AccountingResult) async {
        let usefulLines = textBlocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Find Company Name from a whole OCR line. Word-level OCR boxes often contain only "SRL".
        let companyNoise = try? NSRegularExpression(
            pattern: "\\b(CIF|CUI|COD|FISCAL|BON|NUMAR|DATA|TOTAL|TVA|CLIENT|CUMPARATOR|CASA|AMEF)\\b",
            options: [.caseInsensitive]
        )
        var companyName: String? = nil
        for line in usefulLines.prefix(12) {
            let upper = line.uppercased()
            let hasCompanySuffix = upper.range(of: "\\b(S\\.?R\\.?L\\.?|S\\.?A\\.?|SNC|PFA|II|IF)\\b", options: .regularExpression) != nil
            let hasNoise = companyNoise?.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)) != nil
            if hasCompanySuffix && !hasNoise {
                companyName = line
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if companyName == nil {
            companyName = usefulLines.prefix(6).first(where: { line in
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.count > 3 && cleaned.filter { $0.isNumber }.count < cleaned.count / 2
            })
        }
        result.companyName = companyName
        
        let fullText = usefulLines.joined(separator: "\n").uppercased()
        
        let seriesPattern = "(?:SERIA|SERIE|SERIA:|CHITANTA\\s*SERIA)\\s*([A-Z]{1,5})"
        if let regex = try? NSRegularExpression(pattern: seriesPattern, options: []) {
            let nsString = fullText as NSString
            let match = regex.firstMatch(in: fullText, options: [], range: NSRange(location: 0, length: nsString.length))
            if let m = match, m.numberOfRanges > 1 {
                result.documentSeries = nsString.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        let numberPattern = "(?:NR\\.?|NUMAR(?:\\s+BON(?:\\s+FISCAL)?)?|BON\\s*NR\\.?|FACTURA\\s*NR\\.?|CHITANTA\\s*NR\\.?|BF\\.?)\\s*[:#\\-]*\\s*([0-9]{1,10})"
        if let regex = try? NSRegularExpression(pattern: numberPattern, options: []) {
            let nsString = fullText as NSString
            let match = regex.firstMatch(in: fullText, options: [], range: NSRange(location: 0, length: nsString.length))
            if let m = match, m.numberOfRanges > 1 {
                result.documentNumber = nsString.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        let datePattern = "(?:DATA\\s*[:]*\\s*)?([0-9OQISB]{2}[\\.\\-\\/][0-9OQISB]{2}[\\.\\-\\/]20[0-9OQISB]{2})"
        if let regex = try? NSRegularExpression(pattern: datePattern, options: []) {
            let nsString = fullText as NSString
            let match = regex.firstMatch(in: fullText, options: [], range: NSRange(location: 0, length: nsString.length))
            if let m = match, m.numberOfRanges > 1 {
                result.documentDate = normalizeDate(nsString.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func normalizeDate(_ raw: String) -> String {
        let repaired = CUI.repairOCRDigits(raw)
        let separator = repaired.first(where: { ".-/".contains($0) }) ?? "."
        let parts = repaired.split(whereSeparator: { ".-/".contains($0) }).map(String.init)
        guard parts.count == 3,
              var day = Int(parts[0]),
              var month = Int(parts[1]),
              var year = Int(parts[2]) else {
            return repaired
        }
        if day > 31, let first = parts[0].first, first == "8" || first == "6" || first == "9" {
            day = Int("0" + String(parts[0].dropFirst())) ?? day
        }
        if month > 12, let first = parts[1].first, first == "8" || first == "6" || first == "9" {
            month = Int("0" + String(parts[1].dropFirst())) ?? month
        }
        if year < 2000 { year += 2000 }
        let sep = String(separator)
        return "\(String(format: "%02d", day))\(sep)\(String(format: "%02d", month))\(sep)\(String(format: "%04d", year))"
    }
}

class CuiExtractorAgent: AccountingAgent {
    var buyerCui: String?
    
    init(buyerCui: String? = nil) {
        self.buyerCui = buyerCui
    }
    
    func process(textBlocks: [String], boxes: [OCRBoxItem], result: inout AccountingResult) async {
        let (best, _, candidates) = CUI.candidates(fromLines: textBlocks, buyerCui: buyerCui)
        result.cui = best
        result.cuiRequiresVerification = true
        result.anafCandidates = candidates
    }
}

class FinancialAmountsAgent: AccountingAgent {
    func process(textBlocks: [String], boxes: [OCRBoxItem], result: inout AccountingResult) async {
        let fullText = boxes.map { $0.text }.joined(separator: " ").uppercased()
        
        let sortedHeights = boxes.map { $0.h }.sorted()
        let medianHeight = sortedHeights.isEmpty ? 15.0 : sortedHeights[sortedHeights.count / 2]
        
        // Gather all decimal amounts on this receipt using our new helper with context checks
        var allAmounts: [Double] = []
        for line in textBlocks {
            allAmounts.append(contentsOf: FinancialExtraction.amounts(in: line))
        }
        
        // --- TOTAL EXTRACTION ---
        let totalKeywords = ["TOTAL", "T0TAL", "TIAL", "TlAL", "SUMA", "ACHITAT", "PLATA"]
        var totalFound = false
        var totalAmount: Double? = nil
        let nonTotalKeywords = ["SUBTOTAL", "TOTAL TVA", "TVA TOTAL", "TOTAL TAXA", "TOTAL TAXE", "REST"]

        for line in textBlocks.reversed() {
            let upper = line.uppercased()
            if nonTotalKeywords.contains(where: { upper.contains($0) }) { continue }
            guard totalKeywords.contains(where: { upper.contains($0) }) else { continue }
            let amounts = FinancialExtraction.amounts(in: line).filter { val in
                val > 1.0 && ![21.0, 19.0, 11.0, 9.0, 5.0].contains(val)
            }
            if let val = amounts.last {
                totalAmount = val
                totalFound = true
                break
            }
        }
        
        for box in boxes {
            if totalFound { break }
            let cleanText = box.text.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
            if cleanText.contains("SUBTOTAL") {
                continue
            }
            if totalKeywords.contains(where: { cleanText.contains($0) || (cleanText.count <= $0.count + 2 && cleanText.isFuzzyMatch($0, tolerance: 1)) }) {
                // Check if this "TOTAL" is actually "TOTAL TVA" by checking nearby text
                let nearbyText = boxes.filter { b in
                    let dist = sqrt(pow(b.x - box.x, 2) + pow(b.y - box.y, 2))
                    return dist < medianHeight * 2.0 && !(b.x == box.x && b.y == box.y)
                }.map { $0.text.uppercased() }.joined(separator: " ") + " " + box.text.uppercased()
                
                var checkText = nearbyText
                checkText = checkText.replacingOccurrences(of: "TVA INCLUS", with: "")
                checkText = checkText.replacingOccurrences(of: "TVA INCL", with: "")
                checkText = checkText.replacingOccurrences(of: "TAXE INCLUSE", with: "")
                checkText = checkText.replacingOccurrences(of: "TAXA INCLUSA", with: "")
                if checkText.contains("TVA") || checkText.contains("TAXA") || checkText.contains("TAXE") {
                    continue
                }
                
                // Find the nearest box containing a decimal number
                let candidates = boxes.filter { b in
                    !(b.x == box.x && b.y == box.y)
                }.sorted { b1, b2 in
                    let d1 = pow(b1.x - box.x, 2) + pow(b1.y - box.y, 2)
                    let d2 = pow(b2.x - box.x, 2) + pow(b2.y - box.y, 2)
                    return d1 < d2
                }
                
                for cand in candidates.prefix(8) {
                    let extracted = FinancialExtraction.amounts(in: cand.text)
                    if let val = extracted.first, val > 1.0 {
                        // Sanity: skip if the number is likely a percentage
                        if val == 21.00 || val == 19.00 || val == 11.00 || val == 9.00 || val == 5.00 { continue }
                        totalAmount = val
                        totalFound = true
                        break
                    }
                }
            }
            if totalFound { break }
        }
        
        // Fallback TOTAL
        if !totalFound {
            let totalPattern = "(?i)(?:TOTAL|T0TAL|SUMA|ACHITAT)(?:\\s+DE)?(?:\\s+PLATA)?\\s*(?:LEI)?\\s*[:=]*\\s*([0-9]+[.,][0-9]{2})"
            if let regex = try? NSRegularExpression(pattern: totalPattern, options: []),
               let match = regex.firstMatch(in: fullText, options: [], range: NSRange(location: 0, length: fullText.utf16.count)) {
                let matchedString = (fullText as NSString).substring(with: match.range(at: 1))
                if let val = Double(matchedString.replacingOccurrences(of: ",", with: ".")) {
                    totalAmount = val
                    totalFound = true
                }
            }
        }
        
        let isReceipt = result.documentType == "Chitanță POS" || result.documentType == "Chitanță de mână"
        
        if isReceipt {
            result.totalAmount = totalAmount
            result.vatAmount = 0
            result.vatPercentages = "-"
            result.baseAmount = totalAmount
            result.vatRequiresVerification = false
        } else {
            // Get document date
            var docDate: Date? = nil
            if let dateStr = result.documentDate {
                let formatter = DateFormatter()
                let formats = ["dd.MM.yyyy", "dd/MM/yyyy", "dd-MM-yyyy", "yyyy-MM-dd"]
                for format in formats {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: dateStr) {
                        docDate = date
                        break
                    }
                }
            }
            
            let validRates = RomanianVAT.validRates(documentDate: docDate)
            
            // 1. GATHER ALL PERCENTAGES FROM THE DOCUMENT
            let pctPattern = "\\b([0-9]{1,2})(?:[.,][0-9]{1,2})?\\s*%"
            var rates: [Double] = []
            if let pctRegex = try? NSRegularExpression(pattern: pctPattern, options: []) {
                let matches = pctRegex.matches(in: fullText, options: [], range: NSRange(location: 0, length: fullText.utf16.count))
                for match in matches {
                    let pctStr = (fullText as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")
                    if let rate = Double(pctStr), !rates.contains(rate) {
                        rates.append(rate)
                    }
                }
            }
            
            rates = rates.filter { validRates.contains($0) }
            if rates.isEmpty {
                rates = [validRates.first ?? 21.0]
            }
            
            var breakdowns: [VatBreakdown] = []
            let hasMultipleRates = rates.count > 1
            
            // 3. PURE MATHEMATICAL MATCHING (Rotation & Spatial Invariant)
            for rate in rates {
                if rate == 0.0 { continue }
                var vatAmount: Double? = nil
                var baseAmount: Double? = nil
                
                // Match Method A: Daca avem Totalul, testam daca vreun numar este TVA-ul (vat = total * rate / (100 + rate))
                if !hasMultipleRates, let total = totalAmount {
                    let expectedVat = (total * rate) / (100.0 + rate)
                    for val in allAmounts {
                        if abs(val - expectedVat) <= 0.06 {
                            vatAmount = val
                            break
                        }
                    }
                }
                
                // Match Method B: Cautam Baza si TVA direct in numerele extrase
                if vatAmount == nil {
                    for baseCand in allAmounts {
                        for vatCand in allAmounts {
                            if baseCand == vatCand { continue }
                            if abs(vatCand - baseCand * (rate / 100.0)) <= 0.05 {
                                baseAmount = baseCand
                                vatAmount = vatCand
                                break
                            }
                        }
                        if vatAmount != nil { break }
                    }
                }
                
                if let base = baseAmount, let vat = vatAmount {
                    let pctString = "\(Int(rate))%"
                    if !breakdowns.contains(where: { $0.percentage == pctString }) {
                        breakdowns.append(VatBreakdown(
                            percentage: pctString,
                            vatAmount: (vat * 100).rounded() / 100,
                            baseAmount: (base * 100).rounded() / 100
                        ))
                    }
                    continue
                }

                // Reconcile and calculate base
                let (recTotal, recVat, _, warning) = FinancialExtraction.reconcile(
                    total: totalAmount,
                    vat: vatAmount,
                    rate: rate,
                    allAmountsOnReceipt: allAmounts
                )
                
                if let t = recTotal, let v = recVat {
                    let base = ((t - v) * 100).rounded() / 100
                    let pctString = "\(Int(rate))%"
                    if !breakdowns.contains(where: { $0.percentage == pctString }) {
                        breakdowns.append(VatBreakdown(percentage: pctString, vatAmount: v, baseAmount: base))
                    }
                    totalAmount = t
                    if let warn = warning {
                        result.fiscalWarnings.append(warn)
                    }
                }
            }
            
            if breakdowns.isEmpty {
                if let t = totalAmount {
                    let rate = validRates.first ?? 21.0
                    let (recTotal, recVat, _, warning) = FinancialExtraction.reconcile(
                        total: t,
                        vat: nil,
                        rate: rate,
                        allAmountsOnReceipt: allAmounts
                    )
                    if let t = recTotal, let v = recVat {
                        let base = ((t - v) * 100).rounded() / 100
                        breakdowns.append(VatBreakdown(percentage: "\(Int(rate))%", vatAmount: v, baseAmount: base))
                        if let warn = warning {
                            result.fiscalWarnings.append(warn)
                        }
                    }
                }
            }
            
            if !breakdowns.isEmpty {
                result.vatBreakdowns = breakdowns
                let sumVat = breakdowns.map { $0.vatAmount }.reduce(0, +)
                result.vatAmount = (sumVat * 100).rounded() / 100
                result.vatPercentages = breakdowns.map { $0.percentage }.joined(separator: ", ")
                result.vatRequiresVerification = false
                
                if totalAmount == nil {
                    let sumBase = breakdowns.map { $0.baseAmount }.reduce(0, +)
                    result.totalAmount = ((sumBase + result.vatAmount!) * 100).rounded() / 100
                    result.baseAmount = sumBase
                } else {
                    result.totalAmount = totalAmount
                    result.baseAmount = ((totalAmount! - result.vatAmount!) * 100).rounded() / 100
                }
                result.totalRequiresVerification = false
            } else {
                result.totalAmount = totalAmount
                result.vatAmount = 0
                result.vatPercentages = "-"
                result.baseAmount = totalAmount
                result.vatRequiresVerification = true
            }
        }
    }
}

class FiscalComplianceAgent: AccountingAgent {
    var buyerCui: String?
    
    init(buyerCui: String?) {
        self.buyerCui = buyerCui
    }
    
    func process(textBlocks: [String], boxes: [OCRBoxItem], result: inout AccountingResult) async {
        let fullText = textBlocks.joined(separator: " ").uppercased()
        
        if result.documentType == "Bon Fiscal" {
            // Regula 1: Daca lipseste CUI cumparator de pe document
            if let bCui = buyerCui, !bCui.isEmpty {
                let normalizedFullText = fullText.replacingOccurrences(of: " ", with: "")
                let normalizedBuyerCui = bCui.uppercased().replacingOccurrences(of: " ", with: "")
                if !normalizedFullText.contains(normalizedBuyerCui) {
                    result.fiscalWarnings.append("Atenție: Bonul fiscal nu conține CUI-ul cumpărătorului (\(bCui)). TVA-ul este complet nedeductibil!")
                    result.documentTypeRequiresVerification = true
                }
            } else {
                result.fiscalWarnings.append("Sfat: Introduceți CUI-ul clientului pentru a verifica deductibilitatea bonului.")
            }
            
            // Regula 2: Verificare limita 100 EUR
            let eurRate = await fetchBnrEurRate()
            if let total = result.totalAmount {
                let limitRON = eurRate * 100.0
                if total > limitRON {
                    result.fiscalWarnings.append(String(format: "Atenție: Bonul fiscal depășește limita de ~100 EUR (%.2f RON) pentru a fi considerat factură simplificată.", limitRON))
                    result.totalRequiresVerification = true
                }
            }
        }
        
        if result.documentType == "Factură" {
            // Verificare numar si serie (reguli simple)
            let hasSeria = fullText.contains("SERIA") || fullText.contains("SERIE")
            let hasNumar = fullText.contains("NR.") || fullText.contains("NUMAR") || fullText.contains("NO.")
            
            if !hasSeria && !hasNumar {
                result.fiscalWarnings.append("Atenție: Documentul a fost clasificat ca Factură, dar nu conține elemente obligatorii clare (Seria / Numărul).")
                result.documentTypeRequiresVerification = true
            }
        }
    }
    
    private func fetchBnrEurRate() async -> Double {
        // Fallback rate in case of network failure
        let fallbackRate = 5.0
        guard let url = URL(string: "https://www.bnr.ro/nbrfxrates.xml") else { return fallbackRate }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let xmlString = String(data: data, encoding: .utf8) {
                // Simplest XML parsing via Regex to find <Rate currency="EUR">4.97</Rate>
                let pattern = "<Rate currency=\"EUR\">([0-9.]+)</Rate>"
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let nsString = xmlString as NSString
                    let results = regex.matches(in: xmlString, options: [], range: NSRange(location: 0, length: nsString.length))
                    if let match = results.first, match.numberOfRanges > 1 {
                        let matchedString = nsString.substring(with: match.range(at: 1))
                        if let rate = Double(matchedString) {
                            return rate
                        }
                    }
                }
            }
        } catch {
            return fallbackRate
        }
        return fallbackRate
    }
}

// MARK: - Agent Validare Contabila (Cunostinte Fiscale Romania 2026)

class AccountingValidationAgent: AccountingAgent {
    func process(textBlocks: [String], boxes: [OCRBoxItem], result: inout AccountingResult) async {
        let fullText = textBlocks.joined(separator: " ").uppercased()
        
        // === 1. VALIDARE PENTRU COTE TVA CONFORM DATEI ===
        var docDate: Date? = nil
        if let dateStr = result.documentDate {
            let formatter = DateFormatter()
            let formats = ["dd.MM.yyyy", "dd/MM/yyyy", "dd-MM-yyyy", "yyyy-MM-dd"]
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: dateStr) {
                    docDate = date
                    break
                }
            }
        }
        
        if let vatPct = result.vatPercentages {
            let pctPattern = "([0-9]+)%"
            if let regex = try? NSRegularExpression(pattern: pctPattern, options: []),
               let vatPctStr = result.vatPercentages {
                let nsString = vatPctStr as NSString
                let matches = regex.matches(in: vatPctStr, options: [], range: NSRange(location: 0, length: nsString.length))
                for m in matches {
                    let rateStr = nsString.substring(with: m.range(at: 1))
                    if let rate = Double(rateStr) {
                        if let warning = RomanianVAT.warningForRate(rate, documentDate: docDate) {
                            result.fiscalWarnings.append(warning)
                            result.vatRequiresVerification = true
                        }
                    }
                }
            }
        }
        
        // === 2. VALIDARE MATEMATICA: Total = Baza + TVA ===
        validateMathematically(result: &result)
        
        // === 3. CATEGORIZARE CHELTUIELI (Cont Contabil Sugerat) ===
        if result.documentType == "Chitanță de mână" {
            result.suggestedAccount = "5311"
        } else if result.documentType == "Chitanță POS" {
            result.suggestedAccount = "5125"
        } else {
            let fullOcrText = boxes.map { $0.text }.joined(separator: " ")
            let suggestion = AccountSuggestion.suggest(fullText: fullOcrText)
            result.suggestedAccount = suggestion.account
            if let note = suggestion.note {
                result.fiscalWarnings.append(note)
            }
        }
        
        // === 4. AVERTISMENTE SPECIFICE ===
        addSpecificWarnings(result: &result, fullText: fullText)
    }
    
    // Validare: Total = Baza + TVA
    private func validateMathematically(result: inout AccountingResult) {
        guard let total = result.totalAmount,
              let vat = result.vatAmount,
              let base = result.baseAmount else { return }
        
        let expectedTotal = ((base + vat) * 100).rounded() / 100
        let diff = abs(total - expectedTotal)
        
        if diff > 0.02 && diff < total * 0.5 {
            let correctedBase = ((total - vat) * 100).rounded() / 100
            if correctedBase > 0 {
                result.baseAmount = correctedBase
                result.fiscalWarnings.append(String(format: "Corecție automată: Baza recalculată (%.2f) din Total (%.2f) - TVA (%.2f). Diferență detectată: %.2f RON.", correctedBase, total, vat, diff))
            }
        } else if diff >= total * 0.5 {
            result.fiscalWarnings.append(String(format: "⚠️ Eroare gravă: Total (%.2f) ≠ Bază (%.2f) + TVA (%.2f). Diferență: %.2f RON. Verificare manuală necesară!", total, base, vat, diff))
            result.totalRequiresVerification = true
        }
    }
    
    // Avertismente specifice per context
    private func addSpecificWarnings(result: inout AccountingResult, fullText: String) {
        // Restaurant cu posibilitate de factura mixta (11% mancare + 21% alcool)
        let isRestaurant = fullText.contains("RESTAURANT") || fullText.contains("PIZZ") || fullText.contains("FAST FOOD") || fullText.contains("CAFEA") || fullText.contains("MENIU")
        let hasAlcohol = fullText.contains("BERE") || fullText.contains("VIN ") || fullText.contains("WHISKY") || fullText.contains("VODKA") || fullText.contains("COCKTAIL") || fullText.contains("ALCOOL")
        
        if isRestaurant && hasAlcohol {
            result.fiscalWarnings.append("Atenție: Factura de restaurant conține și băuturi alcoolice. TVA-ul poate fi mixt: 11% pentru mâncare, 21% pentru alcool.")
        }
    }
}

public class AccountingOrchestrator {
    public static let shared = AccountingOrchestrator()
    
    // Stocam ultimele box-uri procesate pentru endpoint-ul /debug_boxes
    public var lastBoxesJson: Data?
    
    public func processOcrResult(boxes: [OCRBoxItem], buyerCui: String? = nil, forcedDocumentType: String? = nil) async -> [AccountingResult] {
        // Generate textBlocks (grouped by lines) for legacy regex usage
        var textBlocks: [String] = []
        if !boxes.isEmpty {
            // Detect if boxes are from a rotated image (median h >> median w)
            let sortedWidths = boxes.map { $0.w }.sorted()
            let sortedHeights = boxes.map { $0.h }.sorted()
            let medianW = sortedWidths[sortedWidths.count / 2]
            let medianH = sortedHeights[sortedHeights.count / 2]
            let isRotated = medianH > medianW * 1.5
            
            if isRotated {
                // ROTATED: lines run vertically. Group by X, sort within line by Y.
                let sortedByX = boxes.sorted { $0.x < $1.x }
                var lines: [[OCRBoxItem]] = []
                var currentLine = [sortedByX[0]]
                let xTolerance = medianW * 0.5
                
                for box in sortedByX.dropFirst() {
                    if abs(box.x - currentLine[0].x) < xTolerance {
                        currentLine.append(box)
                    } else {
                        lines.append(currentLine)
                        currentLine = [box]
                    }
                }
                lines.append(currentLine)
                
                textBlocks = lines.map { line -> String in
                    let sortedLine = line.sorted { $0.y < $1.y }
                    return sortedLine.map { $0.text }.joined(separator: " ")
                }
                print("[PROCESS] Rotated image detected (medianH=\(Int(medianH)) > medianW=\(Int(medianW))*1.5). Grouped \(lines.count) lines by X axis.")
            } else {
                // NORMAL: lines run horizontally. Group by Y, sort within line by X.
                let sortedByY = boxes.sorted { $0.y < $1.y }
                var lines: [[OCRBoxItem]] = []
                var currentLine = [sortedByY[0]]
                let yTolerance = medianH * 0.4
                
                for box in sortedByY.dropFirst() {
                    if abs(box.y - currentLine[0].y) < yTolerance {
                        currentLine.append(box)
                    } else {
                        lines.append(currentLine)
                        currentLine = [box]
                    }
                }
                lines.append(currentLine)
                
                textBlocks = lines.map { line -> String in
                    let sortedLine = line.sorted { $0.x < $1.x }
                    return sortedLine.map { $0.text }.joined(separator: " ")
                }
            }
        }
        
        var result = AccountingResult()
        
        let agents: [AccountingAgent] = [
            DocumentClassificationAgent(),
            DocumentDetailsAgent(),
            CuiExtractorAgent(buyerCui: buyerCui),
            FinancialAmountsAgent(),
            FiscalComplianceAgent(buyerCui: buyerCui),
            AccountingValidationAgent()
        ]
        
        for agent in agents {
            await agent.process(textBlocks: textBlocks, boxes: boxes, result: &result)
        }
        
        if let forced = forcedDocumentType {
            result.documentType = forced
            result.documentTypeRequiresVerification = false
            if forced == "Chitanță de mână" || forced == "Chitanță POS" {
                result.vatAmount = 0
                result.vatPercentages = "-"
                result.baseAmount = result.totalAmount
                result.vatRequiresVerification = false
                result.vatBreakdowns = nil
            }
            if forced == "Chitanță de mână" {
                result.suggestedAccount = "5311"
            } else if forced == "Chitanță POS" {
                result.suggestedAccount = "5125"
            }
        }
        
        // --- SPLIT LOGIC ---
        // Daca utilizatorul are mai multe cote TVA (sau doar una explicita din breakdown), 
        // dorim sa generam un rand separat pentru fiecare.
        if let breakdowns = result.vatBreakdowns, breakdowns.count > 0 {
            var splitResults: [AccountingResult] = []
            for b in breakdowns {
                var splitCopy = result
                splitCopy.vatPercentages = b.percentage
                splitCopy.vatAmount = b.vatAmount
                splitCopy.baseAmount = b.baseAmount
                // Setam totalul per rand ca suma dintre Baza aferenta si TVA-ul aferent.
                splitCopy.totalAmount = breakdowns.count > 1 ? ((b.baseAmount + b.vatAmount) * 100).rounded() / 100 : (result.totalAmount ?? ((b.baseAmount + b.vatAmount) * 100).rounded() / 100)
                // Curatam vectorul intern
                splitCopy.vatBreakdowns = nil
                splitResults.append(splitCopy)
            }
            return splitResults
        }
        
        return [result]
    }
    
    private func extractCUI(from text: String) -> String? {
        let clean = text.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        
        let pattern = "[0-9]{2,10}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsStr = clean as NSString
        let matches = regex.matches(in: clean, options: [], range: NSRange(location: 0, length: nsStr.length))
        
        for match in matches {
            let candidate = nsStr.substring(with: match.range)
            if CUI.isValid(candidate) {
                return candidate
            }
        }
        return nil
    }
    
    private func isBuyerCUIBox(_ box: OCRBoxItem, in boxes: [OCRBoxItem], medianHeight: CGFloat) -> Bool {
        let text = box.text.uppercased()
        let buyerKeywords = ["CLIENT", "CUMP", "BENEF", "CNP", "C.N.P"]
        
        for kw in buyerKeywords {
            if text.contains(kw) {
                return true
            }
        }
        
        for other in boxes {
            if other.x == box.x && other.y == box.y { continue }
            
            let otherText = other.text.uppercased()
            var hasBuyerKeyword = false
            for kw in buyerKeywords {
                if otherText.contains(kw) {
                    hasBuyerKeyword = true
                    break
                }
            }
            if !hasBuyerKeyword { continue }
            
            let dy = box.y - other.y
            let dx = box.x - other.x
            
            if abs(dy) < Double(medianHeight) * 1.5 && dx > 0 && dx < Double(medianHeight) * 12.0 {
                return true
            }
            
            if dy > 0 && dy < Double(medianHeight) * 2.5 && abs(dx) < Double(medianHeight) * 6.0 {
                return true
            }
        }
        
        return false
    }
    
    private func isSellerCUIBox(_ box: OCRBoxItem, in boxes: [OCRBoxItem], medianHeight: CGFloat) -> String? {
        guard let cui = extractCUI(from: box.text) else { return nil }
        
        if isBuyerCUIBox(box, in: boxes, medianHeight: medianHeight) {
            return nil
        }
        
        let text = box.text.uppercased()
        let sellerKeywords = ["CIF", "CUI", "CODFISCAL", "FISCAL", "C.I.F.", "C.F.", "RO"]
        
        var hasSellerKeyword = false
        for kw in sellerKeywords {
            if text.contains(kw) {
                hasSellerKeyword = true
                break
            }
        }
        
        if !hasSellerKeyword {
            for other in boxes {
                if other.x == box.x && other.y == box.y { continue }
                let otherText = other.text.uppercased()
                var otherHasKeyword = false
                for kw in sellerKeywords {
                    if otherText.contains(kw) {
                        otherHasKeyword = true
                        break
                    }
                }
                if !otherHasKeyword { continue }
                
                let dy = abs(box.y - other.y)
                let dx = abs(box.x - other.x)
                
                if dy < Double(medianHeight) * 2.0 && dx < Double(medianHeight) * 12.0 {
                    hasSellerKeyword = true
                    break
                }
            }
        }
        
        if hasSellerKeyword {
            return cui
        }
        
        return nil
    }

    // Separa cutiile de text in documente distincte
    // STRATEGIA CASCADA (robust pentru orice tip de imagine/PDF):
    //   Nivel 1: CUI anchors (COD FISCAL / Cod Identificare Fiscala / CIF standalone)
    //   Nivel 2: BON FISCAL anchors (fallback daca OCR nu detecteaza CUI)
    //   Nivel 3: Union-Find spatial proximity (fallback final pentru imagini fara text fiscal)
    // Dupa fiecare nivel: Pass 2 split daca un cluster contine mai multe CUI-uri
    func clusterBoxes(_ boxes: [OCRBoxItem]) -> [[OCRBoxItem]] {
        guard boxes.count > 1 else { return [boxes] }
        
        let sortedHeights = boxes.map { $0.h }.sorted()
        let medianHeight = Double(sortedHeights[sortedHeights.count / 2])
        
        // === STOCARE PENTRU /debug_boxes ===
        do {
            struct BoxDump: Codable {
                let text: String; let x: Double; let y: Double; let w: Double; let h: Double
            }
            let dumpBoxes = boxes.map { BoxDump(text: $0.text, x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let jsonData = try encoder.encode(dumpBoxes)
            AccountingOrchestrator.shared.lastBoxesJson = jsonData
        } catch {}
        
        print("[CLUSTER] === START === boxes=\(boxes.count), medianHeight=\(medianHeight)")
        
        // =====================================================================
        // HELPER FUNCTIONS
        // =====================================================================
        
        func isBuyerText(_ text: String) -> Bool {
            let t = text.uppercased()
            return t.contains("CLIENT") || t.contains("CUMP") || t.contains("BENEF") || t.contains("CNP")
        }
        
        // Sortare finala: pe Y apoi pe X
        func sortClusters(_ clusters: inout [[OCRBoxItem]]) {
            clusters.sort {
                let y0 = $0.map { $0.y }.min() ?? 0
                let y1 = $1.map { $0.y }.min() ?? 0
                let x0 = $0.map { $0.x }.min() ?? 0
                let x1 = $1.map { $0.x }.min() ?? 0
                if abs(y0 - y1) < medianHeight * 5.0 { return x0 < x1 }
                return y0 < y1
            }
        }
        
        // =====================================================================
        // FIND CUI ANCHORS
        // =====================================================================
        
        var cuiAnchors: [OCRBoxItem] = []
        
        for box in boxes {
            if isBuyerText(box.text) { continue }
            let upper = box.text.uppercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: ".", with: "")
            if upper.contains("CODFISCAL") || upper.contains("CODIDENTIFICARE") || upper.contains("IDENTIFICAREFISCALA") {
                let numbersOnly = box.text.filter { $0.isNumber }
                if numbersOnly.count >= 5 {
                    var dup = false
                    for e in cuiAnchors {
                        if abs(e.x - box.x) < medianHeight * 3 && abs(e.y - box.y) < medianHeight * 2 {
                            dup = true; break
                        }
                    }
                    if !dup {
                        cuiAnchors.append(box)
                        print("[CLUSTER] CUI anchor: '\(box.text)' x=\(Int(box.x)) y=\(Int(box.y))")
                    }
                }
            }
        }
        
        // "CIF" standalone
        for box in boxes {
            if isBuyerText(box.text) { continue }
            let trimmed = box.text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ".", with: "")
            if trimmed == "CIF" || trimmed == "C I F" || trimmed == "CIF:" {
                for box2 in boxes {
                    if abs(box2.x - box.x) < medianHeight * 2 {
                        let hasLongNumber = box2.text.replacingOccurrences(of: " ", with: "")
                            .filter { $0.isNumber }.count >= 7
                        if hasLongNumber {
                            var dup = false
                            for e in cuiAnchors {
                                if abs(e.x - box.x) < medianHeight * 3 && abs(e.y - box.y) < medianHeight * 2 {
                                    dup = true; break
                                }
                            }
                            if !dup {
                                cuiAnchors.append(box)
                                print("[CLUSTER] CIF standalone: '\(box.text)' x=\(Int(box.x)) y=\(Int(box.y))")
                            }
                            break
                        }
                    }
                }
            }
        }
        
        print("[CLUSTER] Found \(cuiAnchors.count) CUI anchors")
        
        // =====================================================================
        // RECURSIVE BISECTION CLUSTERING
        // Splits box groups along the axis where CUI anchors have the largest
        // gap, using actual box position gaps rather than midpoints.
        // Works universally: rotated, 2D grids, single columns, any layout.
        // =====================================================================
        
        if cuiAnchors.count > 1 {
            
            func getAnchorsIn(_ group: [OCRBoxItem]) -> [OCRBoxItem] {
                return cuiAnchors.filter { anchor in
                    group.contains { $0.x == anchor.x && $0.y == anchor.y && $0.text == anchor.text }
                }
            }
            
            func findBestGapSplit(_ group: [OCRBoxItem], axis: String) -> Double? {
                let anchorsInGroup = getAnchorsIn(group)
                if anchorsInGroup.count < 2 { return nil }
                
                let centers: [Double]
                let anchorPositions: [Double]
                
                if axis == "x" {
                    centers = group.map { $0.x + $0.w / 2.0 }.sorted()
                    anchorPositions = anchorsInGroup.map { $0.x + $0.w / 2.0 }
                } else {
                    centers = group.map { $0.y + $0.h / 2.0 }.sorted()
                    anchorPositions = anchorsInGroup.map { $0.y + $0.h / 2.0 }
                }
                
                var bestGap: Double = 0
                var bestSplit: Double? = nil
                
                for i in 1..<centers.count {
                    let gap = centers[i] - centers[i - 1]
                    if gap <= bestGap { continue }
                    
                    let splitPoint = (centers[i - 1] + centers[i]) / 2.0
                    
                    let leftAnchors = anchorPositions.filter { $0 < splitPoint }.count
                    let rightAnchors = anchorPositions.filter { $0 >= splitPoint }.count
                    
                    if leftAnchors > 0 && rightAnchors > 0 {
                        bestGap = gap
                        bestSplit = splitPoint
                    }
                }
                
                return bestSplit
            }
            
            func recursiveSplit(_ group: [OCRBoxItem], depth: Int = 0) -> [[OCRBoxItem]] {
                let anchorsInGroup = getAnchorsIn(group)
                
                if anchorsInGroup.count <= 1 {
                    return [group]
                }
                
                let splitX = findBestGapSplit(group, axis: "x")
                let splitY = findBestGapSplit(group, axis: "y")
                
                func gapSize(_ group: [OCRBoxItem], _ axis: String, _ splitPoint: Double?) -> Double {
                    guard let sp = splitPoint else { return 0 }
                    let centers: [Double]
                    if axis == "x" {
                        centers = group.map { $0.x + $0.w / 2.0 }.sorted()
                    } else {
                        centers = group.map { $0.y + $0.h / 2.0 }.sorted()
                    }
                    let leftMax = centers.filter { $0 < sp }.max() ?? sp
                    let rightMin = centers.filter { $0 >= sp }.min() ?? sp
                    return rightMin - leftMax
                }
                
                var gapX = gapSize(group, "x", splitX)
                var gapY = gapSize(group, "y", splitY)
                
                var finalSplitX = splitX
                var finalSplitY = splitY
                
                // Fallback: midpoint between most distant anchors
                if gapX == 0 && gapY == 0 {
                    let anchorXs = anchorsInGroup.map { $0.x + $0.w / 2.0 }.sorted()
                    let anchorYs = anchorsInGroup.map { $0.y + $0.h / 2.0 }.sorted()
                    let xSpread = (anchorXs.last ?? 0) - (anchorXs.first ?? 0)
                    let ySpread = (anchorYs.last ?? 0) - (anchorYs.first ?? 0)
                    
                    if xSpread >= ySpread {
                        var bestG = 0.0
                        for i in 1..<anchorXs.count {
                            let g = anchorXs[i] - anchorXs[i - 1]
                            if g > bestG { bestG = g; finalSplitX = (anchorXs[i - 1] + anchorXs[i]) / 2.0 }
                        }
                        gapX = bestG
                    } else {
                        var bestG = 0.0
                        for i in 1..<anchorYs.count {
                            let g = anchorYs[i] - anchorYs[i - 1]
                            if g > bestG { bestG = g; finalSplitY = (anchorYs[i - 1] + anchorYs[i]) / 2.0 }
                        }
                        gapY = bestG
                    }
                }
                
                let left: [OCRBoxItem]
                let right: [OCRBoxItem]
                
                if gapX >= gapY, let sp = finalSplitX {
                    print("[CLUSTER] Depth \(depth): Split on X at \(Int(sp)) (gap=\(Int(gapX)))")
                    left = group.filter { $0.x + $0.w / 2.0 < sp }
                    right = group.filter { $0.x + $0.w / 2.0 >= sp }
                } else if let sp = finalSplitY {
                    print("[CLUSTER] Depth \(depth): Split on Y at \(Int(sp)) (gap=\(Int(gapY)))")
                    left = group.filter { $0.y + $0.h / 2.0 < sp }
                    right = group.filter { $0.y + $0.h / 2.0 >= sp }
                } else {
                    return [group]
                }
                
                var result: [[OCRBoxItem]] = []
                if !left.isEmpty { result.append(contentsOf: recursiveSplit(left, depth: depth + 1)) }
                if !right.isEmpty { result.append(contentsOf: recursiveSplit(right, depth: depth + 1)) }
                return result
            }
            
            var clusters = recursiveSplit(boxes)
            clusters = clusters.filter { $0.count >= 3 }
            
            if clusters.count > 1 {
                sortClusters(&clusters)
                print("[CLUSTER] === DONE (Recursive Bisection) === Returning \(clusters.count) clusters")
                for (i, c) in clusters.enumerated() {
                    let minY = c.map { $0.y }.min() ?? 0
                    let minX = c.map { $0.x }.min() ?? 0
                    print("[CLUSTER]   Cluster \(i): \(c.count) boxes, topLeft=(\(Int(minX)),\(Int(minY)))")
                }
                return clusters
            }
        }
        
        // Single receipt or no CUI anchors - return all as one cluster
        print("[CLUSTER] === DONE === No splitting needed, returning all as 1 cluster")
        return [boxes]
    }
}



// MARK: - Fuzzy String Matching (Levenshtein)

extension String {
    func levenshteinDistance(to string: String) -> Int {
        let empty = [Int](repeating: 0, count: string.count + 1)
        var last = [Int](0...string.count)
        
        for (i, char1) in self.enumerated() {
            var cur = [i + 1] + empty.dropFirst()
            for (j, char2) in string.enumerated() {
                cur[j + 1] = char1 == char2 ? last[j] : Swift.min(last[j], last[j + 1], cur[j]) + 1
            }
            last = cur
        }
        return last.last ?? 0
    }
    
    func isFuzzyMatch(_ other: String, tolerance: Int = 1) -> Bool {
        return self.uppercased().levenshteinDistance(to: other.uppercased()) <= tolerance
    }
}

func isValidCUI(cui: String) -> Bool {
    guard cui.count >= 2 && cui.count <= 10 else { return false }
    guard let _ = Int(cui) else { return false }
    
    let controlKey = "753217532"
    let controlKeyReversed = String(controlKey.reversed())
    let cuiReversed = String(cui.reversed())
    
    var sum = 0
    let cuiArray = Array(cuiReversed)
    let keyArray = Array(controlKeyReversed)
    
    guard let controlDigit = Int(String(cuiArray[0])) else { return false }
    
    for i in 1..<cuiArray.count {
        if i - 1 < keyArray.count {
            if let cNum = Int(String(cuiArray[i])), let kNum = Int(String(keyArray[i - 1])) {
                sum += cNum * kNum
            }
        }
    }
    
    let calcControlDigit = (sum * 10) % 11
    let finalControlDigit = calcControlDigit == 10 ? 0 : calcControlDigit
    
    return finalControlDigit == controlDigit
}
