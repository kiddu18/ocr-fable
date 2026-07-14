# Replay segmentare — banc de test offline

Rejoaca EXACT algoritmul din `ReceiptSegmenterV2.swift` pe cuvintele reale
returnate de server la `GET /debug_boxes`, fara telefon si fara rebuild.

Flux:
1. Procesezi o poza problematica in aplicatie.
2. Deschizi `http://IP:8000/debug_boxes` si salvezi JSON-ul.
3. Transcrii cuvintele in `words.py` (text, x, y, w, h) sau adaugi un loader de JSON.
4. `python3 replay.py` -> vezi clusterele, ce bon/CUI/sume contine fiecare.
5. Ajustezi parametrii/regexurile in Python pana ies corect, apoi portezi in Swift.

Pe Windows, fara Python:

```powershell
node tools\replay_segmentare\replay_node.js tools\replay_segmentare\cases\bonuri.txt
node tools\replay_segmentare\regression_node.js
```

Cazul rezolvat cu acest banc (11.07.2026, poza cu 6 bonuri):
- inainte: 4 clustere, campuri amestecate intre bonuri;
- dupa (ancore extinse + invariantul un-CUI): 6/6 separate corect.
