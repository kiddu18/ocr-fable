//
//  INTEGRARE_VAPOR.swift
//
//  NU se adauga la target — e blocul de cod pe care il COPIEZI in
//  VaporServer.swift, in ruta POST /upload, in locul fluxului vechi.
//
//  Ce inlocuieste:  tot ce e intre
//        let result = await textRecognizer.getOcrResult(data: data)
//  si
//        accountingData = accountingDataArray.first
//  (inclusiv apelul la AccountingOrchestrator.shared.clusterBoxes — dispare complet)
//

// ============================ FLUX NOU =====================================

let plus = TextRecognizerPlus()

// --- Branch PDF (facturi electronice SmartBill etc.) ramane pe drumul vechi
if PDFDocument(data: data) != nil {
    let result = await textRecognizer.getOcrResult(data: data)
    // ... pastreaza aici EXACT logica veche pentru PDF, neschimbata ...
}

// --- 1. Detectie orientare + rotire fizica (o singura data, pe toata poza)
guard let image = await plus.normalizedCGImage(from: data) else {
    return try Self.jsonResponse(.internalServerError, UploadResponse(
        success: false, message: "OCR failed",
        ocr_result: "", image_width: 0, image_height: 0, ocr_boxes: []))
}

// --- 2. OCR pe toata poza, la nivel de CUVANT (serveste doar segmentarii)
let (allWords, W, H) = await plus.wordBoxes(on: image)

// --- 3. Segmentare in bonuri (XY-cut + merge fragmente + split pe antete)
let segments = ReceiptSegmenter.segment(allWords)
print("Segmente (bonuri) detectate: \(segments.count)")

// --- 4. Per bon: crop + contrast + re-OCR curat -> extractia existenta
var accountingDataArray: [AccountingResult] = []
var allBoxesOut: [OCRBoxItem] = []

for (i, seg) in segments.enumerated() {
    let cleanBoxes = await plus.cropAndReOCR(image: image, clusterBoxes: seg)
    allBoxesOut.append(contentsOf: cleanBoxes)
    print("Bon \(i): \(seg.count) cuvinte -> \(cleanBoxes.count) dupa re-OCR")

    let results = await AccountingOrchestrator.shared.processOcrResult(
        boxes: cleanBoxes,
        buyerCui: upload.buyer_cui
    )
    accountingDataArray.append(contentsOf: results)
}

// --- 5. UN SINGUR batch ANAF v9 pentru toate CUI-urile din poza
//        (limita ANAF: 1 request/secunda -> nu apela per bon!)
let cuis = accountingDataArray.compactMap { $0.cui }.filter { CUI.isValid($0) }
let anafInfo = await ANAF.verifyBatch(cuis: cuis)

for i in accountingDataArray.indices {
    guard let cui = accountingDataArray[i].cui, let info = anafInfo[cui] else { continue }
    accountingDataArray[i].companyName      = info.denumire
    accountingDataArray[i].companyAddress   = info.adresa
    accountingDataArray[i].companyIsVatPayer = info.scpTVA
    accountingDataArray[i].cuiRequiresVerification = false   // confirmat de ANAF
}

let accountingData = accountingDataArray.first
let fullText = allBoxesOut.map { $0.text }.joined(separator: " ")

// --- 6. Raspunsul JSON existent, cu variabilele noi:
//        ocr_result: fullText, image_width: W, image_height: H,
//        ocr_boxes: allBoxesOut,
//        accounting_data: accountingData,
//        accounting_data_array: accountingDataArray

// ============================ NOTE =========================================
// * In interiorul lui processOcrResult, inlocuieste vechile functii cu cele
//   din ReceiptPipelinePatch.swift:
//     - validare CUI          -> CUI.isValid / CUI.repairOCRDigits / CUI.candidates
//     - sume                  -> FinancialExtraction.amounts + reconcile
//     - cote TVA              -> RomanianVAT.validRates(documentDate:) + warningForRate
//     - cont contabil sugerat -> AccountSuggestion.suggest(fullText:)
//   si STERGE fallback-ul "cel mai mare numar din text = total".
// * usesLanguageCorrection ramane false pentru bonuri (setat deja in
//   TextRecognizerPlus). Pe PDF/facturi il poti lasa true.
