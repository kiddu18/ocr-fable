# Fix OCR bonuri fiscale — de ce vedeai un singur bon și ce repară fișierele noi

## Diagnostic: cele 6 buguri din versiunea actuală

**1. Serverul calcula toate bonurile, dar răspundea doar cu primul.**
În `INTEGRARE_VAPOR.swift`: `let accountingData = accountingDataArray.first`, iar WebClient-ul randa doar câmpul singular `accounting_data`. Chiar dacă segmentarea găsea 4–5 bonuri, în interfață apărea unul singur.

**2. Bonul ROG GAZ e rotit 90° în poză și dispărea complet.**
Normalizarea de orientare alegea O SINGURĂ orientare pentru toată poza. Pe orientarea câștigătoare, bonul rotit producea 0 cuvinte lizibile, deci nu exista pentru segmentator. Fix: `TextRecognizerPro.detectReceipts` probează toate cele 4 orientări cu OCR `.fast`, rulează `.accurate` pe cele promițătoare, segmentează per orientare și deduplică clusterele suprapuse (IoU > 0.30 în spațiul pozei originale), păstrând varianta cu cele mai multe caractere.

**3. Comparatorul de sortare încălca „strict weak ordering”.**
Comparatorul din vechiul `ReceiptSegmenter` putea returna `true` în ambele sensuri pentru aceeași pereche → comportament nedefinit la `sort` (ordine coruptă sau crash). Fix: cheie lexicografică simplă (bucket de coloană de 400 px, apoi `minY`).

**4. Segmentarea lipea bonuri vecine și rata bonurile fără „NUMAR BON”.**
`mergeFragments` cu toleranță `mh*7` unea bonuri de pe aceeași coloană, iar despărțirea pe ancore depindea exclusiv de textul „NUMAR BON” (Douglas și ROG nu îl au). Fix în `ReceiptSegmenterV2`: ancore extinse (COD FISCAL / C.I.F. / Cod Identificare Fiscala, cu excluderea liniilor CLIENT/CNP), regula „două clustere care arată amândouă a bon nu se unesc niciodată”, CUI-uri de comerciant diferite nu se unesc, toleranță redusă la `mh*4`, tăietura la cel mai mare gol dintre linii.

**5. Operator `<` pe tupluri definit local** intra în conflict cu cel din biblioteca standard → eliminat.

**6. „Aproximările”.** Vechiul cod avea un fallback „cel mai mare număr din text = total” (de aici totaluri de tipul numerelor de card / ID-uri tranzacție) și suprascria valori citite corect. Regula nouă (`FinExtract.reconcile`): o valoare citită de Vision nu e suprascrisă NICIODATĂ în tăcere; corecția matematică se acceptă doar dacă valoarea derivată chiar apare textual pe bon, și întotdeauna cu warning + `totalSource` setat. `usesLanguageCorrection` rămâne `false` pe bonuri (corectorul lingvistic strică numerele).

## Fișierele livrate

| Fișier | Rol |
|---|---|
| `TextRecognizerPro.swift` | OCR multi-orientare, crop + re-OCR per bon, maparea coordonatelor înapoi în poza originală |
| `ReceiptSegmenterV2.swift` | Segmentare XY-cut cu regulile noi de merge/split; `groupLines` partajat |
| `ReceiptExtractor.swift` | Extracție per bon: CUI (checksum + reparare OCR), dată, nr. bon, total, TVA, carburant, plată, cumpărător; DTO-uri Codable |
| `RoAccounting.swift` | Încadrare pe conturi + nota contabilă propusă |
| `AnafValidator.swift` | Client ANAF v9 (batch unic, rate-limit) + rezolvarea candidaților prin potrivirea denumirii |
| `INTEGRARE_UPLOAD_V2.swift` | Blocul de copiat în ruta `POST /upload` |
| `webclient_receipts.js` | Randarea TUTUROR bonurilor în WebClient |
| `ground_truth_test_image.json` | Valorile așteptate pe poza ta de test (criterii de acceptanță) |

## Pași de integrare

1. **Șterge din target**: `ReceiptPipelinePatch.swift` și `TextRecognizerPlus.swift` (altfel ai simboluri duplicate).
2. Adaugă cele 5 fișiere `.swift` noi în target-ul serverului.
3. În `VaporServer.swift`, ruta `POST /upload`: înlocuiește fluxul de imagine cu blocul din `INTEGRARE_UPLOAD_V2.swift`. Branch-ul PDF rămâne neschimbat.
4. În structul `UploadResponse` adaugă `let receipts: [ReceiptResult]?`.
5. În WebClient: adaugă `<div id="receipts"></div>`, include `webclient_receipts.js` și apelează `renderReceipts(json)` după răspuns.

## ANAF v9 — de reținut

- Endpoint: `https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva`, POST cu array JSON `[{"cui": 7745470, "data": "2026-07-10"}]`.
- **Limite**: max 100 CUI per request, 1 request pe secundă → de aceea integrarea face UN SINGUR batch pe poză, nu un apel per bon.
- În v9, `date_generale.cui` vine ca **număr**, nu ca string (parserul din `AnafValidator.swift` acceptă ambele).
- Dubla validare: (1) checksum CUI local (cheia 753217532), cu reparare a confuziilor OCR (O→0, S→5, I→1...); (2) potrivire fuzzy între denumirea oficială ANAF și antetul citit din bon. Un CUI *reparat* e acceptat doar dacă și numele se potrivește (scor ≥ 0.35); un CUI citit corect dar cu nume nepotrivit primește status roșu „verifică manual".

## Note legislative (folosite de cod)

- **Cote TVA de la 01.08.2025** (Legea 141/2025): standard **21%**, redusă **11%**. Bonurile tale din aprilie 2026 sunt corect la 21%. Cotele 19/9/5% sunt acceptate doar pentru documente dinainte de 01.08.2025 (`RoVAT` e conștient de dată).
- **Bon fiscal cu CUI-ul cumpărătorului tipărit = factură simplificată** (art. 319 alin. (12) Cod fiscal, plafon 100 EUR) → dă drept de deducere TVA. Codul marchează `isSimplifiedInvoice` când găsește `CIF/CNP CLIENT`.
- **Combustibil**: TVA și cheltuială deductibile **50%** dacă vehiculul nu e utilizat exclusiv în scop economic, 100% cu foaie de parcurs (art. 298, art. 25 alin. (3) lit. l) CF) → contul 6022, cu nota aferentă.
- **Protocol** (parfumurile Douglas): cont 623, TVA la cadouri deductibilă doar în plafonul de 100 lei/beneficiar.
- **Firmă inactivă la ANAF** → warning explicit: TVA nedeductibilă (art. 11 CF).
- Monografia propusă: `6022/623/604 = 401` (baza), `4426 = 401` (TVA), `401 = 5311` numerar / `5125` card (cu alternativa 5121 card de firmă / 542 decont angajat, explicată în label).

## Criterii de acceptanță pe poza ta

Serverul trebuie să întoarcă **6 bonuri** cu valorile din `ground_truth_test_image.json`, inclusiv:
- bonul ROG GAZ (rotit) — total 146,26, cu CUI-ul rezolvat prin reparare + ANAF sau marcat „incert";
- cele două bonuri MAGISTRAL GAZ ca bonuri SEPARATE (114 și 112);
- Douglas cu 613,10 și cont 623;
- toate cu `mathVerified: true` (mai puțin, eventual, ROG, în funcție de calitatea re-OCR-ului).
