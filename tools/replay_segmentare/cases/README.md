# Corpus de regresie

- bonuri.txt   — poza cu 6 bonuri, dump /debug_boxes (14.07.2026).
                 Asteptat cu V5: 6 clustere curate. Ruleaza:
                 python3 ../replay.py bonuri.txt
- chitante.txt — PDF cu 6 documente, dump din ramura VECHE de PDF:
                 paginile sunt SUPRAPUSE in acelasi spatiu (bug reprodus).
                 Dupa pipeline-ul nou per pagina, dump-urile vor fi per pagina.

Regula: fiecare esec din productie devine un fisier aici + o linie in acest README.
