# Corectii v3 — segmentare si campuri incomplete

Aceasta versiune porneste exclusiv din arhiva
`OCR_Iphone_fixed_universal_complete_v2_2026-07-14.7z` si include toate
fisierele proiectului.

## Corectii generale

- coordonatele OCR verticale sunt normalizate direct in aplicatia Swift, nu
  numai in instrumentul de test; o plansa 3 x 2 ramane 6 documente;
- dupa segmentare, coordonatele sunt transformate inapoi pentru decuparea
  corecta a imaginii originale;
- ultimul fragment dintr-o coloana este recitit pana la marginea de jos a
  paginii, pentru formularele la care prima trecere vede numai antetul;
- campurile `Serie`, `Numar`, `Data` si `Suma` sunt recitite in benzi marite,
  atat normal, cat si cu contrast ridicat;
- numarul documentului are prioritate fata de numerele din adresa, Registrul
  Comertului, telefon, factura, CUI sau cont bancar;
- sunt acceptate variante OCR ale etichetei `Numar` (de exemplu `Nouar`),
  inclusiv formatul cu serie si numar pe aceeasi linie;
- sumele candidate nu mai sunt sortate crescator; alegerea foloseste ordinea
  trecerilor OCR si confirmarea dintre citirea focalizata, citirea bruta,
  scrisul de mana si suma in litere;
- nu exista valori, firme sau pozitii fixate pentru documentele de test.

## Verificari incluse

`tools/replay_segmentare/cases` contine exact dump-urile noi primite. Testul
`node tools/replay_segmentare/regression_node.js` verifica segmentarea 6 bonuri,
segmentarea PDF 3 + 3, regulile pentru numarul documentului, sumele si
contractele de siguranta ale pipeline-ului.

Compilarea si rularea Vision/Vapor trebuie facute in Xcode pe dispozitivul Mac,
deoarece Vision, PDFKit si UIKit nu sunt disponibile pe Windows.
