# Corectii v7 — extractie completa + clasificare + fallback detectie

Baza: dump-urile din `bonuri/` (feedback v5) + screenshot-urile UI cu date lipsa.

## Probleme rezolvate

### Extracție financiară (`ReceiptExtractor.swift`)
- **Douglas total 21,00** → total reconstruit din articole (443 + 243 − 72,90 = **613,10**)
- **TVA 0 peste tot** → cote detectate mai robust (`IOTAL TVA`, `TOTALTVA`, `21X`); daca cota lipseste se foloseste **cota legala** la data documentului + TVA calculat
- **Magistral 188,75 gresit** → corectat din TVA / linia de produs la **180,75**
- **ROG total 140,20** → corectat din litri × pret la **146,26**
- Procente (5/9/11/19/21) **nu mai pot fi alese ca TOTAL**
- CUI Douglas `R022254794` → strip zero din fata → **22254794**
- `Cod Identiticare Fiscala` (OCR) acceptat ca antet CUI

### Clasificare chitanță vs bon (`ChitantaExtractor.swift`)
- `ID TRX/CHITANTA` de pe bonuri **nu** mai e chitanță
- Respinge automat: BON FISCAL, carburant (GPL/motorina), NUMAR BON, AMEF
- Titlul CHITANTA singur nu mai e suficient — cer dovezi de formular

### Pipeline detectie (`VaporServer.swift`)
- Fallback **full-page re-OCR** cand celulele izolate pierd documente
- Dedup pe IoU (acelasi document fizic), pastreaza scorul maxim

### ANAF (`AnafValidator.swift`)
- CUI valid + gasit la ANAF → **confirmat** chiar daca antetul OCR e zgomotos
- Nu mai blocheaza UI-ul pe „NUME DIFERIT!” pentru print termic

### Conturi (`RoAccounting.swift`)
- AMERIS / DONA → 604 farmacie

### Web client
- `processing_mode` default **auto** (nu mai forta `bon`)

## Teste offline (fara iPhone)

```powershell
node tools/replay_segmentare/regression_node.js
```

Valideaza:
- 6 bonuri din dump (totaluri + TVA + CUI)
- Douglas 613,10 / TVA 106,41
- ROG 146,26 / TVA 25,38
- 2× Magistral 180,75 + 183,48
- Ameris multi-cota ~44,67
- MOL nu e clasificat chitanță

## Rebuild pe iPhone

1. Deschide `OcrServer.xcodeproj` in Xcode
2. Clean Build Folder (Shift+Cmd+K)
3. Run pe device
4. In web: tip document **Auto**, CUI cumparator daca e cazul
5. Reproceseaza pozele din `bonuri/`

## Rezultat asteptat pe poza 6 bonuri

| Firmă | Total | TVA | CUI |
|-------|------:|----:|-----|
| Magistral #114 | 180,75 | 31,37 | 34626689 |
| MOL #337 | 188,16 | 32,66 | 7745470 |
| Turist #1076 | 181,15 | 31,44 | 7709175 |
| Magistral #112 | 183,48 | 31,84 | 34626689 |
| Douglas | 613,10 | 106,41 | 22254794 |
| ROG GAZ | 146,26 | 25,38 | (ANAF pe candidati) |
