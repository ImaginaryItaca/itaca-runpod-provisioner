#!/usr/bin/env bash
# ITACA - script d'avvio del pod RunPod (provisioner unico dei workflow Itaca, 2026-10-27).
# Lo lancia il comando d'avvio del template, dopo aver scaricato il repository in /workspace/provisioner.
set -euo pipefail

W=/workspace
P=$W/provisioner
C=$W/ComfyUI
PY=$W/venv/bin/python
WF=$P/Workflows   # cartella dei workflow nel repository (su Linux maiuscole e minuscole contano)

log() { echo "[ITACA $(date +%H:%M:%S)] $*"; }

# 1. ComfyUI, nodi e librerie (Task 3).
bash "$P/installa.sh"

# 2. Pesi dei modelli (Task 4, quando c'è lo script).
if [ -f "$P/pesi.sh" ]; then
  bash "$P/pesi.sh"
fi

# 3. Workflow Itaca nella cartella di ComfyUI (non sovrascrive quelli già presenti sul pod).
mkdir -p "$C/user/default/workflows"
if [ -d "$WF" ]; then
  cp -n "$WF"/*.json "$C/user/default/workflows/" || true
fi

# 4. Avvio di ComfyUI, raggiungibile dal proxy RunPod sulla porta 8188.
log "Avvio ComfyUI (log in $W/comfyui.log)"
cd "$C"
nohup "$PY" main.py --listen 0.0.0.0 --port 8188 > "$W/comfyui.log" 2>&1 &

for i in $(seq 1 120); do
  if curl -sf http://127.0.0.1:8188/object_info > /dev/null; then
    break
  fi
  sleep 5
done

# 5. Controllo: tutti i nodi usati dai workflow devono essere registrati.
if [ -d "$WF" ]; then
  "$PY" "$P/verifica_nodi.py" "$WF" || log "ATTENZIONE: mancano nodi, leggi sopra e in $W/comfyui.log"
else
  log "ATTENZIONE: cartella $WF assente, workflow non copiati né controllati"
fi

log "Pod pronto: ComfyUI sulla porta 8188"
