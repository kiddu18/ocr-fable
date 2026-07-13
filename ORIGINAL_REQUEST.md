# Original User Request

## Initial Request — 2026-07-02T15:33:28+03:00

# Teamwork Project Prompt — Draft

> Status: Launched
> Goal: Craft prompt → get user approval → delegate to teamwork_preview

The goal is to comprehensively test the newly updated iOS OCR Server (specifically the spatial 2D extraction engine for Receipt Totals, VAT, and CUI) to verify that recent logic changes successfully fix edge cases without introducing regressions.

Working directory: e:\OCR Iphone\OcrServer
Integrity mode: benchmark

## Requirements

### R1. Comprehensive Testing of OCR Logic
The agent team must write and execute tests to ensure the `FinancialAmountsAgent` and `CuiExtractorAgent` correctly identify VAT (TVA), Totals, and CUI from various receipt formats, especially handling dynamic vertical/horizontal distances and tricky formatting (e.g., "TOTAL TVA A - 21% 2.08").

### R2. Validation of Recent Fixes
Verify that the recent fixes (ignoring the word "TVA" when searching for "TOTAL", and using dynamic `yTol` based on `box.h`) are functioning correctly and will not crash or fail on unexpectedly formatted receipts.

### R3. Automated Test Suite
Build a fully automated test script (in Swift or Python) that runs through dozens of simulated OCR JSON scenarios/boxes to stress-test the implementation using external libraries if needed. 

### R4. Manual Code Review
Perform a thorough manual review of the VaporServer.swift codebase to trace the logic of the newly implemented functions, simulating step-by-step logic to guarantee edge-case safety.

## Acceptance Criteria

### Testing & Verification
- [ ] A complete test-suite using external testing libraries has been created and executed without errors.
- [ ] The test suite successfully passes the edge cases reported by the user (CUI override and TOTAL vs TOTAL TVA discrimination).
- [ ] A final report details the test results and confirms the robustness of the updated spatial logic, proving it objectively through passing programmatic test cases.
- [ ] A summary of the manual codebase review is delivered, certifying no logic flaws remain.
