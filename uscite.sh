#!/usr/bin/env bash
# ITACA - mette le uscite di ComfyUI in un unico zip da scaricare con JupyterLab (Task 5 del provisioner, 2026-10-27).
# JupyterLab scarica solo file singoli, non cartelle: per le sequenze EXR serve lo zip.
# Uso (terminale di JupyterLab):  bash /workspace/provisioner/uscite.sh            -> tutta la cartella output
#                                 bash /workspace/provisioner/uscite.sh C1/<data>  -> solo una sottocartella
set -euo pipefail

O=/workspace/ComfyUI/output
Z=/workspace/uscite_$(date +%Y-%m-%d_%H-%M).zip
cd "$O"

if [ $# -gt 0 ]; then
  python3 -m zipfile -c "$Z" "$@"
else
  shopt -s nullglob
  voci=(*)
  if [ ${#voci[@]} -eq 0 ]; then
    echo "[ITACA] La cartella output è vuota"
    exit 0
  fi
  python3 -m zipfile -c "$Z" "${voci[@]}"
fi

echo "[ITACA] Creato $Z ($(du -h "$Z" | cut -f1))"
echo "[ITACA] In JupyterLab: cartella /workspace, tasto destro sul file, Download. Poi cancellalo per liberare spazio."
