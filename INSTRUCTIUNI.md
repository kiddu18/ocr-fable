# INSTRUCȚIUNI DE INSTALARE — OCR Iphone (pipeline bonuri multiple)

Ai 5 fișiere. Două intră în Xcode ca fișiere noi, unul e ghid de copiere
în cod, două sunt referință/test. Ordinea de mai jos e ordinea de lucru.

---

## Pasul 1 — Adaugă fișierele noi în Xcode

În Xcode, click dreapta pe folderul **OcrServer** (același în care sunt
`VaporServer.swift` și `TextRecognizer.swift`) → **Add Files to "OcrServer"...**

Adaugă:

| Fișier | Ce conține | Target membership |
|---|---|---|
| `TextRecognizerPlus.swift` | Vision: orientare, word boxes, crop+enhance+re-OCR | ✅ OcrServer |
| `ReceiptPipelinePatch.swift` | ReceiptSegmenter, CUI, ANAF v9, RomanianVAT, FinancialExtraction, AccountSuggestion | ✅ OcrServer |

Bifează "Copy items if needed" și target-ul aplicației.
Ambele compilează standalone — nu au dependențe în afară de Vision,
CoreImage și `OCRBoxItem` (care e deja în VaporServer.swift).

## Pasul 2 — Modifică ruta /upload din VaporServer.swift

Deschide `INTEGRARE_VAPOR.swift` (NU îl adăuga la target — e doar șablon).

În `VaporServer.swift`, în handlerul rutei `POST /upload`:

1. Găsește linia `let result = await textRecognizer.getOcrResult(data: data)`.
2. Șterge tot de acolo până la `accountingData = accountingDataArray.first`
   inclusiv — adică și blocul de debug `===== OCR DEBUG =====` și apelul
   `AccountingOrchestrator.shared.clusterBoxes(boxes)`. Clustering-ul pe
   linii dispare definitiv.
3. Lipește în loc blocul din `INTEGRARE_VAPOR.swift`.
4. În `UploadResponse`-ul de succes, schimbă variabilele:
   `result?.text` → `fullText`, `result?.image_width` → `W`,
   `result?.image_height` → `H`, `result?.boxes` → `allBoxesOut`.
5. Branch-ul de PDF (facturi SmartBill) rămâne pe `getOcrResult` vechi.

## Pasul 3 — Înlocuiește funcțiile din agenți

Tot în `VaporServer.swift`, în `AccountingOrchestrator` / agenți:

| Vechi (de șters/înlocuit) | Nou (din ReceiptPipelinePatch.swift) |
|---|---|
| `isValidCUI` (accepta 2 cifre!) | `CUI.isValid` (min 4 cifre) + `CUI.repairOCRDigits` |
| căutarea CUI în tot textul | `CUI.candidates(fromLines:buyerCui:)` — exclude linii CLIENT/CNP și CUI-ul cumpărătorului |
| fallback "cel mai mare număr = total" | **ȘTERGE-L.** Folosește `FinancialExtraction.amounts(in:)` (format obligatoriu X,XX + blacklist) |
| total/TVA acceptate orbește | `FinancialExtraction.reconcile(total:vat:rate:)` — corecție matematică bidirecțională |
| cote TVA hardcodate 19/9/5 | `RomanianVAT.validRates(documentDate:)` — 21/11 din 01.08.2025 + `warningForRate` |
| apel ANAF v8 per bon | `ANAF.verifyBatch(cuis:)` — v9, UN SINGUR request pentru toată poza |
| cont contabil | `AccountSuggestion.suggest(fullText:)` — 6022/3022 combustibil, 623 protocol/restaurant, 628/604 diverse |

## Pasul 4 — Build & test

1. Build pe iPhone, pornește serverul Vapor.
2. Trimite poza de test cu cele 6 bonuri la `POST /upload` cu
   `buyer_cui=30630040`.
3. În consolă trebuie să vezi `Segmente (bonuri) detectate: 5–6`
   (ROG GAZ poate rămâne parțial — print termic foarte slab).
4. Verifică în `accounting_data_array`:
   - Magistral #114 → CUI 34626689, total 180.75, TVA 31.37
   - MOL #337 → total 188.16, TVA 32.66
   - Turist Service #1076 → CUI 7709175, total 181.15
   - Magistral #112 → total 183.48
   - Douglas → total 613.10, TVA 106.41
   - nicăieri CUI-ul tău 30630040, niciun total de miliarde.

## Fișiere de referință (nu intră în Xcode)

- `RAPORT_DIAGNOSTIC.md` — de ce eșua pipeline-ul vechi + rezultatele PoC
- `poc_pipeline.py` — implementarea Python completă, validată pe poza ta;
  e sursa de adevăr dacă vrei să compari comportamentul pas cu pas
  (rulează cu `python3 poc_pipeline.py poza.png`)

## Dacă un bon tot iese prost

- Bon termic decolorat → crește `contrast` din `enhanceForThermalPrint`
  de la 1.35 spre 1.6 și `sharpness` spre 0.6.
- Bonuri lipite nedespărțite → scade `minGapX` în `ReceiptSegmenter`
  (acum 1.0 × înălțimea mediană a cuvintelor).
- Un bon spart în două → crește pragul de merge vertical (acum 7 × mh).
