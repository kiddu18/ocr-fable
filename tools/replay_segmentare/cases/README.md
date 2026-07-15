# Corpus de regresie

- bonuri.txt   — poza cu 6 bonuri, dump /debug_boxes (14.07.2026).
                 Asteptat cu V5: 6 clustere curate. Ruleaza:
                 python3 ../replay.py bonuri.txt
- chitante.txt — PDF cu 6 documente, dump din ramura VECHE de PDF:
                 paginile sunt SUPRAPUSE in acelasi spatiu (bug reprodus).
                 Dupa pipeline-ul nou per pagina, dump-urile vor fi per pagina.

- `bonuri_feedback_v4.txt` — dump-ul exact trimis dupa rularea arhivei v4.
  Tourist si Magistral erau lipite; asteptat: exact 6 clustere.
- `chitante_feedback_v4.txt` — dump-ul exact trimis dupa rularea arhivei v4.
  Pastreaza dovada contaminarii dintre crop-uri (ABAD/Daisy in pagina
  Ameris/FAN/Dona); regresia structurala verifica eliminarea traseului care a
  produs aceasta contaminare.

Regula: fiecare esec din productie devine un fisier aici + o linie in acest README.
