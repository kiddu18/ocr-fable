# Diagnostic OCR Iphone — testul cu bonuri multiple

## Ce am făcut

Am rulat OCR pe poza ta de test (6 bonuri, rotite 90°, lipite între ele) și am trecut box-urile prin logica exactă din `VaporServer.swift` (via portul Python `test_spatial_ocr.py`). Apoi am construit un proof-of-concept cu arhitectura corectă și l-am validat pe aceeași poză.

## Rezultatul pipeline-ului actual (eșec total)

- **9 clustere în loc de 6 bonuri**, majoritatea fără sens
- Totaluri extrase din ID-uri: `4000884157` (numărul RC de la MOL), `5000388218` (seria AMEF), `1076` (numărul bonului), și `30630040` — **CUI-ul cumpărătorului luat drept total**
- CUI-uri "valide": `25`, `27`, `19` — checksum-ul CUI acceptă orice număr ≥ 2 cifre, deci validează gunoaie
- Nume firmă: `None` aproape peste tot

## Cauzele fundamentale (în ordinea gravității)

### 1. Arhitectura: OCR pe toată poza → clustering pe coordonate text
Când bonurile sunt lipite, OCR-ul (și Apple Vision, și tesseract) unește rânduri din 2 bonuri vecine într-un singur box: `"MAGISTRAL GAZ SRL MOL ROMANIA PETROLEUM PRODUCTS S.R.L."`. Odată ce un box conține text din 2 bonuri, nicio logică downstream nu-l mai poate separa. **Clusteringul recursiv pe ancore CUI din `segmentReceipts` nu poate funcționa pe input-ul ăsta.**

**Fix:** inversează ordinea — segmentează întâi (imagine sau box-uri de CUVINTE, nu de linii), apoi extrage per bon:
1. XY-cut recursiv: împarte recursiv la cel mai mare "jgheab" de spațiu gol care traversează complet regiunea (pe X sau pe Y). Jgheaburile interne ale unui bon (coloana dintre etichete și sume) sunt întrerupte de rândurile late (antet, adresă), deci nu declanșează split; jgheaburile dintre bonuri sunt continue.
2. Split semantic: dacă un cluster conține ≥ 2 ancore de antet (`NUMAR BON FISCAL`, `COD FISCAL`, `Cod Identificare Fiscala`), taie între ele. Un bon are exact un antet.
3. Merge înapoi fragmentele antet/corp: clustere suprapuse pe X > 50% și gap vertical mic, cu regula "niciodată 2 antete în același cluster".

### 2. Rotația
Bonurile din poză sunt rotite 90°. Rulează recunoașterea la 4 orientări pe fiecare crop (sau folosește `VNRecognizeTextRequest` cu orientare explicită) și păstrează varianta cu cele mai multe caractere recunoscute / confidence maxim.

### 3. `isValidCUI` acceptă 2 cifre
`guard cui.count >= 2` validează "25", "19", "21". Minim practic: **4 cifre** (firmele reale de pe bonuri au 6–9). În plus, cere context: candidatul trebuie să apară după `COD FISCAL / C.I.F. / CUI / RO` sau să aibă prefix RO, și **niciodată** pe o linie cu `CLIENT / CNP / BENEF / CUMPARATOR`.

### 4. Fallback-ul "cel mai mare număr" pentru total
De aici vin totalurile de miliarde. Șterge-l complet sau restrânge-l drastic:
- Format obligatoriu `\d{1,5}[.,]\d{2}` (numerele fără separator zecimal nu sunt sume)
- Blacklist de context pe linie: `RC:`, `AUTOR`, `TRX`, `NR. CARD`, `CNP`, `C.I.F`, `EJTRZ`, `ID UNIC`, `AUTORIZARE`, telefoane
- Validare matematică obligatorie: `TVA ≈ Total × cota / (100 + cota)` cu toleranță 0,05–0,06

### 5. Validarea matematică poate și CORECTA, nu doar semnala
Cazul real din test: OCR a citit totalul `188,75` dar TVA-ul `31,37` la 21%. `31,37 × 121/21 = 180,75`, iar `180,75` există ca sumă pe bon → totalul corect e 180,75 (confirmă și `4,04 × 44,74`). Regulă: dacă (total, TVA) nu sunt consistente matematic, derivează totalul din TVA și acceptă-l dacă suma derivată apare pe bon. La fel invers.

### 6. Reparare cifre ghidată de checksum
OCR confundă frecvent `0↔8`, `O→0`, `@→0`, `I→1`, `S→5`, `B→8`. Pentru candidații CUI: aplică substituțiile, apoi dacă checksum-ul tot nu trece, încearcă variante cu o singură cifră modificată/adăugată și validează cu checksum + ANAF. În test a recuperat `7709175` din `RO77@9175`. La date: `81/04/2026` → `01/04/2026`.

### 7. Cotele TVA — actualizate pentru 2026
Codul folosește `[21, 19, 11, 9, 5]` nediferențiat. Corect, în funcție de data documentului:
- **de la 01.08.2025 (Legea 141/2025): 21% standard, 11% redusă** (5% și 9% eliminate)
- **9% doar tranzitoriu pentru locuințe, până la 31.07.2026** — nu apare pe bonuri de casă
- înainte de 01.08.2025: 19%, 9%, 5%
- dacă pe un bon din 2026 apare cota 19%, e aproape sigur o eroare OCR → semnalează

### 8. API-ul ANAF: v8 e depășit
Codul apelează `PlatitorTvaRest/api/v8/ws/tva`. Versiunea curentă e **v9**: `https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva`, cu structură JSON diferită — `denumire`, `adresa` sunt în `found[0].date_generale`, iar statutul TVA în `found[0].inregistrare_scop_Tva.scpTVA`. Limite: max ~100 CUI-uri per request, 1 request/secundă — deci **trimite toate CUI-urile din poză într-un singur batch**, nu câte unul.

**Validare nume + CUI:** după răspunsul ANAF, compară fuzzy (Levenshtein normalizat pe tokenuri) `denumire` de la ANAF cu numele firmei extras din antet. Match → `cuiRequiresVerification = false` și **suprascrie numele OCR cu denumirea oficială ANAF**. Mismatch → păstrează CUI-ul dar marchează pentru verificare manuală. Asta rezolvă și cazurile de reparare de cifre: generezi 2–3 candidați CUI, îi verifici în același batch ANAF și-l alegi pe cel al cărui nume oficial seamănă cu antetul bonului.

## Rezultatele PoC-ului pe poza ta

| Bon | Firma | CUI | Nr. | Data | Total | Cota | TVA | Bază | Validare mat. |
|---|---|---|---|---|---|---|---|---|---|
| Magistral #114 | MAGISTRAL GAZ SRL | 34626689 | 114 | 01.04.2026 | **180,75** (auto-corectat din 188,75) | 21% | 31,37 | 149,38 | ✓ |
| MOL #337 | MOL ROMANIA PETROLEUM PRODUCTS S.R.L. | 7745470* | 337 | 04.04.2026 | 188,16 | 21% | 32,66 | 155,50 | ✓ |
| Turist Service #1076 | TURIST SERVICE SRL | 7709175 (reparat din `RO77@9175`) | 1076 | 17.04.2026 | 181,15 | 21% | 31,44 | 149,71 | ✓ |
| Magistral #112 | MAGISTRAL GAZ SRL | 34626689 | 112 | 22.04.2026 | 183,48 (derivat din TVA, "TOTAL" citit "TiAl") | 21% | 31,84 | 151,64 | ✓ |
| Douglas | PARFUMERIE DOUGLAS SRL | 22254794 | — | 16.04.2026 | 613,10 | 21% | 106,41 | 506,69 | ✓ |
| ROG GAZ #0084 | — | — | — | 10.04.2026 | 146,26 | 21% | 25,38 | — | print termic slab; necesită preprocesare contrast per crop |

\* cu batch ANAF v9 + fuzzy match pe denumire, candidatul trunchiat `774547_` se rezolvă la 7745470.

CUI-ul cumpărătorului `30630040` (INSECT TERMINATOR 3D SRL) — exclus corect pe toate bonurile.

Notă: PoC-ul rulează pe tesseract, care e vizibil mai slab decât Apple Vision pe termice. Pe iPhone, cu aceeași arhitectură, rata de succes va fi mai mare.

## Sugestii de conturi contabile (implementate în PoC)

| Conținut bon | Cont | Observații fiscale |
|---|---|---|
| motorină / benzină / GPL | 6022 (sau 3022 dacă stocați) | TVA deductibilă 50% dacă vehiculul nu e utilizat exclusiv economic (art. 298 CF); 100% cu foaie de parcurs |
| parfumerie / cadouri | 623 protocol (sau 6588) | protocol: deductibilitate limitată la impozitul pe profit |
| restaurant / catering | 623 | mâncare 11%, alcool 21% pe același bon |
| consumabile / diverse | 604 / 628 | — |
| bon fără CUI cumpărător ≤ 100 EUR | oricare | deductibil ca factură simplificată doar dacă are CUI-ul cumpărătorului tipărit |

## Fișiere livrate

- `poc_pipeline.py` — pipeline-ul complet funcțional (segmentare XY-cut + extracție hardened), rulabil pe orice poză
- `ReceiptPipelinePatch.swift` — componentele Swift de integrat în `VaporServer.swift`: XY-cut pe box-uri de cuvinte, split semantic pe ancore, CUI hardened cu reparare de cifre, ANAF v9 batch cu fuzzy match pe denumire, cote TVA 2026 date-aware, validare + corecție matematică, sugestii de conturi
