# Corectii v5 — feedback dupa compilarea v4

Aceasta versiune porneste exclusiv din arhiva
`OCR_Iphone_fixed_universal_complete_v4_2026-07-14.zip` trimisa dupa testarea
pe Mac. Dump-urile `bonuri.txt` si `chitante.txt` din 15.07.2026 sunt pastrate
integral in corpusul de regresie.

## Cauza regresiei v4

Pipeline-ul segmenta documentele o data pe pagina, apoi extindea unele crop-uri
spre marginea paginii si segmenta din nou rezultatul OCR. Aceasta combinatie
putea:

- absorbi textul documentului vecin;
- transforma un document in mai multe fragmente;
- elimina documente reale la deduplicarea finala;
- combina seria, data, CUI-ul sau suma din documente diferite.

Dump-ul PDF confirma contaminarea: text ABAD si Daisy apare in aceleasi zone OCR
cu Ameris si FAN. Dump-ul bonurilor confirma si un caz separat in care doua
bonuri alaturate nu aveau un gol alb suficient pentru taierea geometrica simpla.

## Solutia generala

- separarea se face o singura data, inainte de re-OCR;
- fiecare detectie fizica produce exact un rezultat final;
- fiecare document primeste o celula izolata, limitata la jumatatea distantei
  fata de vecinii de pe rand, coloana sau diagonala;
- celula este transformata corect in oricare dintre cele patru orientari OCR;
- re-OCR-ul nu mai poate extinde liber crop-ul in documentul vecin;
- nu mai exista a doua segmentare si deduplicare dupa re-OCR;
- bonurile lipite lateral sunt separate numai cand ambele parti contin dovezi
  de document fiscal complet (antet fiscal si total/footer), nu dupa pozitii sau
  valori specifice pozei;
- daca re-OCR-ul izolat citeste prea putin, ramane activ fallback-ul primei
  citiri, fara pierderea documentului.

Nu sunt fixate in cod CUI-uri, comercianti, serii, numere, date, sume sau
coordonate provenite din fisierele de test.

## Verificari incluse

Comanda `node tools/replay_segmentare/regression_node.js` verifica:

- 6 bonuri pe corpusul anterior;
- exact 6 bonuri pe dump-ul nou v4;
- 3 + 3 documente in corpusul PDF curat;
- cotele multiple Ameris si TVA total 44,67;
- campurile DSF/14332, DI/200861 si suma FAN in clusterele lor;
- eliminarea traseului recursiv care a produs fragmentele si dublurile;
- existenta celulelor izolate si a maparii lor pentru toate orientarile.

Compilarea Vision/UIKit/Vapor necesita Xcode pe macOS. Mediul Windows poate
rula integral replay-ul geometric, testele extractorilor si verificarile
statice, dar nu poate executa Apple Vision.
