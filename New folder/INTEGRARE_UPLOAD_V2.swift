//
//  INTEGRARE_UPLOAD_V2.swift
//  NU se adauga la target — e blocul de cod pe care il COPIEZI in VaporServer.swift,
//  in ruta POST /upload, in locul fluxului vechi. Branch-ul PDF ramane neschimbat.
//
//  DE CE VEDEAI UN SINGUR BON: fluxul vechi punea in raspuns
//      let accountingData = accountingDataArray.first
//  iar WebClient-ul randa doar campul singular `accounting_data`.
//  Fluxul nou intoarce `receipts: [ReceiptResult]` — TOATE bonurile —
//  si pastreaza campurile vechi pentru compatibilitate.
//

// ============================ FLUX NOU =====================================

let pro = TextRecognizerPro()

// --- 0. Branch PDF (facturi electronice etc.) ramane pe drumul vechi
// if PDFDocument(data: data) != nil { ...logica veche, neschimbata... }

// --- 1. Imaginea de baza (aplica EXIF-ul pozei)
guard let base = pro.baseCGImage(from: data) else {
    return try Self.jsonResponse(.internalServerError, UploadResponse(
        success: false, message: "Could not decode image",
        ocr_result: "", image_width: 0, image_height: 0, ocr_boxes: []))
}

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
var receipts: [ReceiptResult] = []
var allBoxesBase: [OCRBoxItem] = []

for (i, det) in detections.enumerated() {
    let rotImg = rotatedImage(det.turns)
    let clean = await pro.cropAndReOCR(rotatedImage: rotImg, clusterBoxes: det.words)
    let lines = ReceiptSegmenterV2.groupLines(clean)

    var r = ReceiptExtractor.extract(lines: lines, index: i,
                                     buyerCuiHint: nil /* sau upload.buyer_cui daca ai campul */)
    r.orientation = det.turns
    r.bboxX = Double(det.baseRect.minX)
    r.bboxY = Double(det.baseRect.minY)
    r.bboxW = Double(det.baseRect.width)
    r.bboxH = Double(det.baseRect.height)
    receipts.append(r)

    // box-urile, mapate inapoi in spatiul pozei originale (debug overlay)
    allBoxesBase.append(contentsOf: TextRecognizerPro.mapWordsToBase(
        clean, turns: det.turns, rotatedW: rotImg.width, rotatedH: rotImg.height))
}

// --- 4. UN SINGUR batch ANAF v9 pentru toate CUI-urile din poza
//        (limita ANAF: 1 request/secunda -> nu apela per bon!)
var allCandidates: [String] = []
for r in receipts {
    allCandidates.append(contentsOf: r.anafCandidates)
    if let b = r.buyerCui, RoCUI.isValid(b) { allCandidates.append(b) }
}
let anafInfo = await AnafClient.shared.verifyBatch(allCandidates)

// --- 5. Dubla validare per bon: checksum + potrivire de denumire ANAF
for i in receipts.indices {
    let header = receipts[i].merchantNameOCR ?? ""
    let res = AnafResolver.resolve(candidates: receipts[i].anafCandidates,
                                   checksumWasValid: receipts[i].cuiChecksumValid,
                                   ocrHeader: header,
                                   anaf: anafInfo)
    receipts[i].anaf.checked = !receipts[i].anafCandidates.isEmpty
    receipts[i].anaf.status = res.status
    receipts[i].anaf.nameScore = res.score

    if let comp = res.company {
        receipts[i].cui = res.cui
        receipts[i].anaf.found = true
        receipts[i].anaf.denumire = comp.denumire
        receipts[i].anaf.adresa = comp.adresa
        receipts[i].anaf.scpTVA = comp.scpTVA
        if comp.statusInactiv == true {
            receipts[i].warnings.append("ATENTIE: firma figureaza INACTIVA la ANAF — TVA nedeductibila (art. 11 CF).")
        }
        if comp.scpTVA == false {
            receipts[i].warnings.append("Firma NU e platitoare de TVA la data interogarii — verifica deducerea.")
        }
    } else if res.status == "cui_incert_necesita_verificare" || res.status == "cui_negasit_anaf" {
        receipts[i].warnings.append("CUI neconfirmat de ANAF — necesita verificare manuala.")
    }

    // numele cumparatorului, daca CUI-ul lui a fost si el verificat
    if let b = receipts[i].buyerCui, let comp = anafInfo[b] {
        receipts[i].buyerName = comp.denumire ?? receipts[i].buyerName
    }
}

// --- 6. Raspunsul JSON: pastreaza campurile vechi + adauga `receipts`
let fullText = receipts.map { $0.rawText }.joined(separator: "\n\n---\n\n")

// In structul UploadResponse adauga campul:
//     let receipts: [ReceiptResult]?
// si construieste raspunsul asa:
//
// return try Self.jsonResponse(.ok, UploadResponse(
//     success: true,
//     message: "\(receipts.count) bonuri detectate",
//     ocr_result: fullText,
//     image_width: base.width,
//     image_height: base.height,
//     ocr_boxes: allBoxesBase,
//     receipts: receipts))

// ============================ NOTE =========================================
// * STERGE din target: ReceiptPipelinePatch.swift, TextRecognizerPlus.swift
//   (altfel ai simboluri duplicate cu fisierele noi).
// * usesLanguageCorrection ramane false pe bonuri (setat in TextRecognizerPro).
//   Pe PDF/facturi il poti lasa true.
// * Vechiul fallback "cel mai mare numar din text = total" NU mai exista —
//   sursa totalurilor "de miliarde" era exact acel fallback.
