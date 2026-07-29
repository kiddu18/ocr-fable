# Material de referință (test, NU antrenament hardcodat)

| Fișier | Conținut real |
|--------|----------------|
| `1facfbd9-….jfif` | Poză cu **6 bonuri fiscale** (Magistral×2, MOL, Douglas, Turist, ROG GAZ) — aceeași scenă ca dump-ul `bonuri.txt` |
| `document2026-01-22-083155.pdf` | **NU e scan de bonuri**: e un PDF de 160 pagini (ROF ELCEN / Electrocentrale București). Nu folosi ca ground truth pentru pipeline-ul de bonuri/chitanțe. |

## Cum se folosesc

- Poza JFIF + dump-urile OCR din folderul părinte sunt **cazuri de regresie** (verifică că algoritmul general nu se strică).
- Extractorul din `OcrServer/*.swift` **nu conține** CUI-uri, sume, serii sau denumiri din aceste documente ca reguli de business.
- Conturile contabile pot avea cuvinte-cheie de **categorie** (MOTORINA, PARFUMERIE, FARMACI…) — aplicabile oricărui comerciant din acea categorie, nu doar firmelor din poza de test.

## Principii extractor universal

1. Segmentare geometrică (XY-cut + ancore fiscale generice: COD FISCAL, NUMAR BON, CHITANȚA).
2. Câmpuri prin regex de **etichete** RO (TOTAL, TVA, C.I.F., DATA…), nu prin listă de furnizori.
3. Validare matematică (TVA ↔ total, litri × preț) pe orice bon.
4. CUI: checksum oficial + reparare OCR + ANAF batch — fără whitelist de CUI-uri.
5. Clasificare bon vs chitanță pe **markeri de document**, nu pe nume de firmă.
