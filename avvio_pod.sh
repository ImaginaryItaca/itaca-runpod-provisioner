#!/usr/bin/env bash
# ITACA - servizi RunPod e supervisore del provisioner. Task 1, 2026-10-27.
# E il processo principale avviato dal comando del template.
set -Eeuo pipefail
set +m  # setsid deve ricevere figli che non sono gia capigruppo.

W=/workspace
P=$W/provisioner
PID_SERVIZI=
PID_AVVIO=
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
  # I gruppi creati con setsid comprendono anche installatori, Python e Jupyter.
  for pid in "$PID_SERVIZI" "$PID_AVVIO"; do
    if [[ -n "$pid" ]]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
    fi
  done
  for pid in "$PID_SERVIZI" "$PID_AVVIO"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  # Il file originale vive sul disco del contenitore; si conserva l'ultimo log nel volume.
  if [[ -n "$PID_SERVIZI" && -f /jupyter.log ]]; then
    cp -- /jupyter.log "$W/jupyter.log" 2>/dev/null || true
  fi
  exit "$codice"
}

trap pulisci EXIT
trap 'log "Arresto del pod richiesto (SIGINT)"; exit 130' INT
trap 'log "Arresto del pod richiesto (SIGTERM)"; exit 143' TERM
trap 'codice=$?; log "ERRORE durante: $FASE (codice $codice, riga $LINENO)" >&2; exit "$codice"' ERR

for strumento in flock setsid tee curl python3; do
  command -v "$strumento" >/dev/null || fallisci 1 "Strumento richiesto assente: $strumento"
done
[[ -d "$W" ]] || fallisci 1 "Cartella $W assente"
[[ -f /start.sh ]] || fallisci 1 "/start.sh assente: controlla l'immagine del template"
[[ -f "$P/avvio.sh" ]] || fallisci 1 "File obbligatorio assente: $P/avvio.sh"
[[ -n ${JUPYTER_PASSWORD:-} ]] || fallisci 1 "JUPYTER_PASSWORD vuota: controlla la variabile e il segreto RunPod"

exec 9> "$W/.itaca-pod.lock"
flock -n 9 || fallisci 1 "Un altro supervisore ITACA del pod e gia in esecuzione"

# Il registro resta disponibile nel volume; tee rende visibili i messaggi anche nei log RunPod.
# tee non deve ereditare il blocco sul file.
: >> "$W/provision.log"
exec > >(tee -a "$W/provision.log" 9>&-) 2>&1
log "Avvio del supervisore ITACA"

FASE="controllo delle porte prima dell'avvio"
python3 - <<'PY'
import socket
import sys

for porta in (8188, 8888):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", porta))
        except OSError as e:
            print(f"[ITACA] ERRORE: porta {porta} non disponibile: {e}. Nessun processo esistente verra terminato.", file=sys.stderr)
            sys.exit(1)
PY

FASE="avvio dei servizi RunPod"
log "Avvio /start.sh: servizi della base e JupyterLab"
setsid bash /start.sh 9>&- &
PID_SERVIZI=$!

# Si controlla la pagina di accesso, senza mettere la password in URL o nei log.
servizi_pronti=false
scadenza=$((SECONDS + 120))
while (( SECONDS < scadenza )); do
  kill -0 "$PID_SERVIZI" 2>/dev/null || fallisci 1 "/start.sh e terminato durante l'avvio dei servizi"
  if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 \
      http://127.0.0.1:8888/login > /dev/null 2>&1; then
    servizi_pronti=true
    break
  fi
  sleep 2
done
[[ "$servizi_pronti" == true ]] || fallisci 1 "JupyterLab non risponde sulla porta 8888 entro circa 2 minuti. Il log viene conservato in $W/jupyter.log."
kill -0 "$PID_SERVIZI" 2>/dev/null || fallisci 1 "/start.sh e terminato dopo l'avvio di JupyterLab"
log "JupyterLab risponde sulla porta 8888"

FASE="provisioning e supervisione dei servizi"
setsid bash "$P/avvio.sh" 9>&- &
PID_AVVIO=$!

# Il controllo esplicito evita di perdere un figlio terminato prima di un wait -n.
# wait sul PID terminato conserva il suo codice di uscita.
while :; do
  for pid in "$PID_SERVIZI" "$PID_AVVIO"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      codice=0
      wait "$pid" || codice=$?
      if [[ "$pid" == "$PID_SERVIZI" ]]; then
        nome="servizi RunPod"
      else
        nome="provisioner / ComfyUI"
      fi
      # Questi servizi devono restare attivi: anche un'uscita spontanea con 0 e inattesa.
      if [[ "$codice" -eq 0 ]]; then codice=1; fi
      fallisci "$codice" "$nome terminato senza una richiesta di arresto. Controlla $W/provision.log e $W/comfyui.log."
    fi
  done
  sleep 1
done
