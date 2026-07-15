# Corectii v4 — feedback dupa compilarea v3

Aceasta versiune porneste exclusiv din arhiva ZIP v3 returnata dupa compilarea
pe Mac. Dump-urile noi din 14.07.2026 sunt incluse in regresii.

## Cauze confirmate

- a doua segmentare putea trata antetul si footerul aceluiasi bon ca documente
  separate, desi prima segmentare obtinuse corect cele 6 bonuri;
- extinderea verticala verifica doar vecinii cu aceeasi orientare OCR; un vecin
  detectat in alta orientare putea fi absorbit in documentul curent;
- alternativele OCR focalizate aveau prioritate fata de antetul tiparit si
  puteau inlocui seria sau trunchia numarul;
- OCR-ul focalizat folosea numai prima ipoteza Vision si o banda prea ingusta
  sub titlul chitantelor scrise de mana.

## Corectii generale

- o rafinare este acceptata numai cand fiecare parte are dovezi ca este un
  document autonom; fragmentele antet/corp raman impreuna;
- vecinii verticali sunt comparati in coordonatele fizice ale paginii,
  independent de orientarea folosita pentru OCR;
- extinderea in jos ruleaza numai pentru o chitanta incompleta si numai daca nu
  exista alt document dedesubt;
- seria si numarul folosesc prioritar citirea bruta a antetului tiparit;
- variantele OCR `Nhonar`/`Nouar` sunt tratate ca forme degradate ale etichetei
  `Numar`, inclusiv cand seria este pe aceeasi linie;
- benzile Serie/Numar/Data/Suma sunt recitite normal si cu contrast ridicat,
  iar Vision furnizeaza mai multe ipoteze validate ulterior intre treceri;
- un sir compact de 5-7 cifre este interpretat cu doua zecimale numai in banda
  focalizata si numai imediat dupa eticheta `Suma`;
- nu exista valori comerciale, sume sau pozitii fixate in codul de productie.

## Regresii

`node tools/replay_segmentare/regression_node.js` verifica:

- 6 bonuri complete, fara randuri-fragment;
- 3 + 3 documente pe paginile PDF;
- seria DSF si numarul 14332 din antet;
- varianta `Serie/Nhonar: DI 200861`;
- suma FAN ramane in clusterul FAN;
- Ameris pastreaza cotele 21% si 11%, cu TVA total 44,67;
- antetul si footerul unui bon nu sunt acceptate ca doua documente.

Compilarea Vision/UIKit/Vapor necesita Xcode pe macOS si nu poate fi executata
in mediul Windows folosit pentru pregatirea arhivei.
