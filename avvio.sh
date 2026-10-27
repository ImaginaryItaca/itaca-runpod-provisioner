#!/usr/bin/env bash
# ITACA - provisioning e supervisione di ComfyUI. Revisione Task 1, 2026-10-27.
# Lo avvia avvio_pod.sh; resta attivo finche il processo ComfyUI resta attivo.
set -Eeuo pipefail

W=/workspace
P=$W/provisioner
C=$W/ComfyUI
PY=$W/venv/bin/python
WF=$P/Workflows
PID_COMFY=
PID_FASE=
FASE="controlli iniziali"

log() { echo "[ITACA $(date +%H:%M:%S)] $*"; }

fallisci() {
  local codice=$1
  shift
  log "ERRORE: $*" >&2
  exit "$codice"
}

pulisci() {
  local codice=$?
  trap - EXIT ERR
  trap '' INT TERM
  # Il supervisore del pod ferma anche l'intero gruppo di processi di questo script.
  for pid in "$PID_FASE" "$PID_COMFY"; do
    if [[ -n "$pid" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$PID_FASE" "$PID_COMFY"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  exit "$codice"
}

trap pulisci EXIT
trap 'log "Arresto richiesto (SIGINT)"; exit 130' INT
trap 'log "Arresto richiesto (SIGTERM)"; exit 143' TERM
trap 'codice=$?; log "ERRORE durante: $FASE (codice $codice, riga $LINENO)" >&2; exit "$codice"' ERR

# Attendere con wait permette di ricevere i segnali anche durante installazione e download.
esegui() {
  "$@" 8>&- &
  PID_FASE=$!
  wait "$PID_FASE"
  PID_FASE=
}

controlla_porta() {
  python3 - <<'PY'
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", 8188))
    except OSError as e:
        print(f"[ITACA] ERRORE: porta 8188 non disponibile: {e}. Nessun processo esistente verra terminato.", file=sys.stderr)
        sys.exit(1)
PY
}

comfy_vivo() {
  if kill -0 "$PID_COMFY" 2>/dev/null; then
    return
  fi
  local codice=0
  wait "$PID_COMFY" || codice=$?
  PID_COMFY=
  if [[ "$codice" -eq 0 ]]; then codice=1; fi
  fallisci "$codice" "ComfyUI e terminato durante: $FASE. Controlla $W/comfyui.log."
}

for strumento in flock curl python3; do
  command -v "$strumento" >/dev/null || fallisci 1 "Strumento richiesto assente: $strumento"
done
[[ -d "$W" ]] || fallisci 1 "Cartella $W assente"
exec 8> "$W/.itaca-comfyui.lock"
flock -n 8 || fallisci 1 "Un altro avvio ITACA di ComfyUI e gia in corso"

for file in installa.sh pesi.py verifica_nodi.py; do
  [[ -f "$P/$file" ]] || fallisci 1 "File obbligatorio assente: $P/$file"
done
[[ -d "$WF" ]] || fallisci 1 "Cartella dei workflow assente: $WF"
shopt -s nullglob
workflow=("$WF"/*.json)
[[ ${#workflow[@]} -gt 0 ]] || fallisci 1 "Nessun workflow JSON in $WF"
controlla_porta

FASE="installazione di ComfyUI, nodi e librerie"
log "$FASE"
esegui bash "$P/installa.sh"

FASE="download dei pesi obbligatori"
log "$FASE"
esegui "$PY" -u "$P/pesi.py"

FASE="copia iniziale dei workflow"
mkdir -p "$C/user/default/workflows"
# Si conserva qui la politica precedente. La distribuzione delle versioni e il Task 4.
# Gli errori di copia restano fatali; saltare un file esistente non e un errore.
for file in "${workflow[@]}"; do
  destinazione=$C/user/default/workflows/${file##*/}
  if [[ ! -e "$destinazione" && ! -L "$destinazione" ]]; then
    cp -- "$file" "$destinazione"
  fi
done

FASE="avvio di ComfyUI"
export AUX_ANNOTATOR_CKPTS_PATH=$W/aux_ckpts
controlla_porta
cd "$C"
printf '\n[ITACA %s] Nuovo avvio ComfyUI\n' "$(date -Iseconds)" >> "$W/comfyui.log"
log "Avvio ComfyUI; log in $W/comfyui.log"
"$PY" -u main.py --listen 0.0.0.0 --port 8188 >> "$W/comfyui.log" 2>&1 8>&- &
PID_COMFY=$!

FASE="attesa della risposta di ComfyUI"
pronto=false
scadenza=$((SECONDS + 600))
while (( SECONDS < scadenza )); do
  comfy_vivo
  # /system_stats e una verifica leggera. Il catalogo completo viene controllato dopo.
  if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 \
      http://127.0.0.1:8188/system_stats > /dev/null 2>&1; then
    comfy_vivo
    pronto=true
    break
  fi
  sleep 2
done
[[ "$pronto" == true ]] || fallisci 1 "ComfyUI non risponde entro circa 10 minuti. Controlla $W/comfyui.log."

FASE="verifica dei nodi dei workflow"
esegui "$PY" "$P/verifica_nodi.py" "$WF"
comfy_vivo
log "Pod pronto: ComfyUI risponde sulla porta 8188; pesi e verifica dei nodi completati senza errori."

# Questo script rimane responsabile del processo che ha avviato.
FASE="esecuzione di ComfyUI"
codice=0
wait "$PID_COMFY" || codice=$?
PID_COMFY=
if [[ "$codice" -eq 0 ]]; then codice=1; fi
fallisci "$codice" "ComfyUI e terminato senza una richiesta di arresto. Controlla $W/comfyui.log."
