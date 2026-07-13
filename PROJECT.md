# Project: OCR Server Spatial 2D Engine Fixes

## Architecture
- Module/package boundaries: iOS OCR Server (Vapor app in Xcode), WebClient (HTML/JS frontend).
- Data flow: Camera/upload image -> text recognizer and layout normalization (Vision/TextRecognizerPlus) -> recursive XY-cut receipt segmenter -> enhance crop -> Re-OCR -> extraction agents (VaporServer.swift: Details, CUI, Financials, Compliance, Validation) -> API response -> WebClient rendering and Excel Export.
- Shared interfaces: `AccountingResult` (Swift structure / JSON format between Swift server and WebClient).

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|---|---|---|---|
| 1 | Test Infra Setup & Diagnostics | Run existing python unit tests (test_logic.py, test_adversarial_challenger.py, test_spatial_ocr.py) to assess the baseline state of the codebase. | None | DONE |
| 2 | Implementation of R3 Payment Account Suggestions | Implement 5311/5125 payment account suggestions for Receipts in VaporServer.swift, WebClient/app.js, and python tests/mocks. | M1 | IN_PROGRESS (Conv: 3505d9a4-8f26-49e4-afe4-a5c880834163) |
| 3 | Verification of Requirements (R1-R4) | Run Python verification scripts and verify they pass; verify ANAF double validation, CUI normalization, and 6-receipt segmentation. | M2 | PLANNED |
| 4 | Xcode Compilation Verification | Run build commands for Xcode project/workspace on the system to ensure correct compilation of Vapor server in debug/release. | M3 | PLANNED |

## Interface Contracts
### Vapor Server -> WebClient API
- Route: `/upload` (POST)
- Response field: `accounting_data_array` containing array of `AccountingResult`:
  - `documentType`: String? ("Chitanță de mână", "Chitanță POS", "Bon Fiscal", etc.)
  - `suggestedAccount`: String? ("5311", "5125", or expense accounts)
  - `totalAmount`: Double?
  - `vatAmount`: Double?
  - `baseAmount`: Double?
  - `vatPercentages`: String?
  - `cui`: String?
  - `companyName`: String?
  - `cuiRequiresVerification`: Bool
  - `fiscalWarnings`: [String]

## Code Layout
- `VaporServer.swift` - HTTP routing, agents execution, main logic
- `ReceiptPipelinePatch.swift` - XY-cut segmentation, ANAF, VAT, and financial extraction helper classes
- `TextRecognizerPlus.swift` - rapid orientation, box extraction, crop enhancement
- `WebClient/app.js` - Web UI client script handling upload, rendering, and Excel export
- `test_logic.py` - python mock 6-receipt segmentation and extraction logic test
- `test_adversarial_challenger.py` - python adversarial unittest test suite
