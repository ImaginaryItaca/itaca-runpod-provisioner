#!/usr/bin/env bash
# ITACA - base comune ai due provisioner. 2026-10-28.
# Immagine: runpod/base:1.4.1-cuda1281-ubuntu2404.
# Python, librerie e tutti gli 11 pacchetti sono condivisi; pesi e workflow sono separati.
# Questo file viene caricato da provisiona_qwen.sh o provisiona_ltx.sh.
set -Eeuo pipefail

W=/workspace
C=$W/ComfyUI
N=$C/custom_nodes
PY=$W/venv/bin/python
HF=$W/venv/bin/hf
WF=$C/user/default/workflows/Itaca
SORGENTE=https://raw.githubusercontent.com/ImaginaryItaca/itaca-runpod-provisioner/refs/heads/main
MARCATORE_BASE=$W/.itaca_base_20261028
FILE_PID=$W/itaca_comfyui.pid
LOG_COMFY=$W/comfyui.log
INIZIO_ITACA=$SECONDS

mkdir -p "$W"
exec > >(tee -a "$W/provision.log") 2>&1
log() { echo "[ITACA $(date +%H:%M:%S)] $*"; }
trap 'stato_itaca=$?; echo "[ITACA] ERRORE alla riga $LINENO (codice $stato_itaca). Operazione interrotta." >&2; exit "$stato_itaca"' ERR

# Un solo provisioner alla volta modifica lo stesso ambiente e le cartelle di lavoro.
# Il processo ComfyUI viene avviato con questo descrittore chiuso.
exec 9>"$W/.itaca_provision.lock"
if ! flock -n 9; then
  log "Un altro provisioner e' in corso: attendo che termini."
  flock 9
fi

test -n "${HF_TOKEN:-}" || { log "HF_TOKEN assente nel template"; exit 1; }
export UV_PYTHON_INSTALL_DIR=$W/.uv-python
export UV_CACHE_DIR=$W/.cache/uv
export HF_HOME=$W/.cache/huggingface
export AUX_ANNOTATOR_CKPTS_PATH=$W/aux_ckpts
export HF_HUB_ENABLE_HF_TRANSFER=0
export HF_XET_CHUNK_CACHE_SIZE_BYTES=0

prepara_ambiente() {
  if [ -f "$MARCATORE_BASE" ] && [ -x "$PY" ] && [ -x "$HF" ] && [ -f "$C/main.py" ]; then
    log "Base comune gia pronta: riuso Python, librerie e nodi."
    return
  fi
  # Evita di cambiare un'installazione in uso che non e' stata preparata da questi script.
  if curl -fs --noproxy '*' --connect-timeout 2 --max-time 5 http://127.0.0.1:8188/system_stats > /dev/null; then
    log "ComfyUI e' attivo, ma manca la conferma della base comune."
    log "Ferma ComfyUI prima di preparare la base, oppure usa questi file su un nuovo pod ITACA."
    return 1
  fi
  log "Spazio disponibile sul volume"
  df -h "$W"
  log "Preparo Python 3.13"
  if [ ! -x "$PY" ]; then
    uv venv --python 3.13 "$W/venv"
  fi
  
  # Versioni dei repository rilevate nella portable e indicate nell'inventario.
  clona() {
    local cartella=$1 url=$2 commit=$3
    if [ ! -d "$cartella/.git" ]; then
      git clone --quiet "$url" "$cartella"
    fi
    if ! git -C "$cartella" cat-file -e "$commit^{commit}" 2>/dev/null; then
      git -C "$cartella" fetch --quiet origin "$commit"
    fi
    git -C "$cartella" checkout --quiet "$commit"
  }
  log "Installo ComfyUI e i quattro pacchetti da Git"
  clona "$C" "https://github.com/Comfy-Org/ComfyUI" "483dae4326356b81de05d27aca3f433dd323cc25"
  clona "$N/ComfyUI-LTXVideo" "https://github.com/Lightricks/ComfyUI-LTXVideo" "220e1d45aa0469f518e982102fca4dca92a61862"
  clona "$N/ComfyUI-Video-Depth-Anything" "https://github.com/yuvraj108c/ComfyUI-Video-Depth-Anything" "a0db08e63d1ea571601c45cde4aaee0acdd0544d"
  clona "$N/ComfyUI-VideoHelperSuite" "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite" "4d907bee61e92c2e65af3bd6383a4e4d356126d1"
  clona "$N/ComfyUI-KJNodes" "https://github.com/kijai/ComfyUI-KJNodes" "d3cfe21625e5170126ce06fbfcfe1d88108688c3"
  
  # Gli archivi del Registry possono essere zip anche quando il nome dice tar.gz.
  registry() {
    local nome=$1 url=$2 cartella=$N/$1 temporanea radice
    if [ -f "$cartella/.itaca_versione" ] && [ "$(cat "$cartella/.itaca_versione")" = "$url" ]; then
      log "$nome gia installato"
      return
    fi
    log "Installo $nome"
    temporanea=$(mktemp -d)
    curl -fL --retry 3 "$url" -o "$temporanea/archivio"
    mkdir -p "$temporanea/contenuto"
    if "$PY" -c 'import sys, zipfile; sys.exit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)' "$temporanea/archivio"; then
      "$PY" -m zipfile -e "$temporanea/archivio" "$temporanea/contenuto"
    else
      tar -xzf "$temporanea/archivio" -C "$temporanea/contenuto"
    fi
    radice=$temporanea/contenuto
    if [ ! -f "$radice/__init__.py" ]; then
      radice=$(find "$temporanea/contenuto" -mindepth 2 -maxdepth 2 -name __init__.py -printf '%h\n' | head -n1)
    fi
    if [ -z "$radice" ] || [ ! -f "$radice/__init__.py" ]; then
      log "Archivio di $nome senza __init__.py"
      exit 1
    fi
    mkdir -p "$cartella"
    cp -a "$radice/." "$cartella/"
    echo "$url" > "$cartella/.itaca_versione"
    rm -rf "$temporanea"
  }
  log "Installo i sette pacchetti dal Registry"
  registry "rgthree-comfy" "https://cdn.comfy.org/rgthree/rgthree-comfy/1.0.2608312342/node.zip"
  registry "comfyui_essentials" "https://cdn.comfy.org/matteo/comfyui_essentials/1.1.0/node.tar.gz"
  registry "comfyui_controlnet_aux" "https://cdn.comfy.org/fannovel16/comfyui_controlnet_aux/1.1.5/node.zip"
  registry "comfyui-impact-pack" "https://cdn.comfy.org/drltdata/comfyui-impact-pack/8.28.3/node.zip"
  registry "comfyui-inpaint-cropandstitch" "https://cdn.comfy.org/lquesada/comfyui-inpaint-cropandstitch/3.0.16/node.zip"
  registry "ComfyUI-EasyColorCorrector" "https://cdn.comfy.org/itsjustregi/ComfyUI-EasyColorCorrector/1.2.5/node.zip"
  registry "comfyui-mute-bypass-by-ID" "https://cdn.comfy.org/pixelpainter/comfyui-mute-bypass-by-ID/3.0.3/node.zip"
  
  # Dipendenze dirette dei due workflow: versioni gia rilevate nella portable.
  # Solo opencv-python-headless; escluse le librerie dei nodi non usati nell'inventario.
  # Installazione standard uv: nessun lock da generare o riportare dal pod.
  log "Installo le librerie Python e PyTorch cu128"
  uv pip install --python "$PY" --torch-backend cu128 \
    'torch==2.10.0' \
    'torchvision==0.25.0' \
    'torchaudio==2.10.0' \
    'comfyui-frontend-package==1.55.18' \
    'comfyui-workflow-templates==0.11.96' \
    'comfyui-embedded-docs==0.5.14' \
    'comfy-kitchen==0.2.39' \
    'comfy-aimdo==0.5.6' \
    'torchsde==0.2.6' \
    'numpy==2.4.2' \
    'einops==0.8.2' \
    'transformers==4.57.6' \
    'tokenizers==0.22.2' \
    'sentencepiece==0.2.1' \
    'safetensors==0.7.0' \
    'aiohttp==3.13.3' \
    'yarl==1.22.0' \
    'pyyaml==6.0.3' \
    'pillow==12.1.0' \
    'scipy==1.17.0' \
    'tqdm==4.67.3' \
    'psutil==7.2.2' \
    'alembic==1.18.3' \
    'SQLAlchemy==2.0.46' \
    'filelock==3.20.0' \
    'av==18.1.0' \
    'requests==2.32.5' \
    'simpleeval==1.0.7' \
    'blake3==1.0.8' \
    'kornia==0.8.2' \
    'spandrel==0.4.1' \
    'pydantic==2.12.5' \
    'pydantic-settings==2.12.0' \
    'PyOpenGL==3.1.10' \
    'comfy-angle==0.1.1' \
    'colour-science==0.4.7' \
    'diffusers==0.36.0' \
    'huggingface_hub==0.36.2' \
    'ninja==1.11.1.4' \
    'openimageio==3.2.1.3' \
    'opencv-python-headless==4.13.0.90' \
    'matplotlib==3.10.8' \
    'imageio==2.37.2' \
    'imageio-ffmpeg==0.6.0' \
    'easydict==1.13' \
    'Imath==0.0.2' \
    'OpenEXR==3.4.6' \
    'numba==0.64.0' \
    'importlib_metadata==8.7.1' \
    'scikit-image==0.26.0' \
    'python-dateutil==2.9.0.post0' \
    'fvcore==0.1.5.post20221221' \
    'yapf==0.43.0' \
    'omegaconf==2.3.0' \
    'ftfy==6.3.1' \
    'addict==2.4.0' \
    'yacs==0.1.8' \
    'trimesh[easy]==4.11.2' \
    'albumentations==2.0.8' \
    'scikit-learn==1.8.0' \
    'segment-anything==1.0' \
    'piexif==1.1.3' \
    'dill==0.4.1' \
    'color-matcher==0.6.0' \
    'mss==10.1.0' \
    'rawpy==0.26.1' \
    'timm==1.0.24'
  
  log "Verifico che PyTorch acceda alla GPU e che il token HF sia valido"
  "$PY" -c 'import torch; assert torch.cuda.is_available(), "PyTorch non vede la GPU"; print("GPU:", torch.cuda.get_device_name(0))'
  "$HF" auth whoami

  mkdir -p "$WF" "$C/input" "$C/output"
  touch "$MARCATORE_BASE"
  log "Base comune preparata: i successivi provisioner la riutilizzeranno."
}

# I file parziali rimangono nell'area HF. Solo un download completato viene spostato
# nella cartella standard ComfyUI, senza mantenere split_files nel percorso finale.
scarica() {
  local repo=$1 file=$2 cartella=$3 nome lavoro
  nome=$(basename "$file")
  if [ -s "$cartella/$nome" ]; then
    log "Gia presente: $nome"
    return
  fi
  lavoro=$W/.scaricamenti/$repo
  log "Scarico $nome"
  "$HF" download "$repo" "$file" --local-dir "$lavoro"
  mkdir -p "$cartella"
  mv "$lavoro/$file" "$cartella/$nome"
}

workflow() {
  local nome=$1
  mkdir -p "$WF"
  if [ -f "$WF/$nome" ]; then
    log "Workflow gia presente: $nome"
    return
  fi
  curl -fL --retry 3 "$SORGENTE/Workflows/$nome" -o "$WF/$nome.part"
  "$PY" -m json.tool "$WF/$nome.part" > /dev/null
  mv "$WF/$nome.part" "$WF/$nome"
}


comfy_risponde() {
  curl -fs --noproxy '*' --connect-timeout 2 --max-time 5 http://127.0.0.1:8188/system_stats |
    "$PY" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "comfyui_version" in d.get("system", {}) else 1)' 2>/dev/null
}

pid_comfy_valido() {
  [ -f "$FILE_PID" ] || return 1
  PID_COMFY=$(cat "$FILE_PID")
  [[ "$PID_COMFY" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$PID_COMFY" 2>/dev/null || return 1
  [ "$(readlink "/proc/$PID_COMFY/cwd" 2>/dev/null)" = "$C" ] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$PID_COMFY/cmdline")" == *"main.py"* ]]
}

avvia_comfy() {
  if comfy_risponde; then
    log "ComfyUI e' gia attivo: continuo a usare la stessa istanza."
    log "Pesi e workflow pronti. Salva il lavoro aperto e ricarica la pagina di ComfyUI."
    log "Operazione completata in $((SECONDS - INIZIO_ITACA)) secondi."
    return
  fi

  if pid_comfy_valido; then
    log "ComfyUI e' gia in avvio (PID $PID_COMFY): attendo senza avviarne un'altra copia."
  else
    # Il CORS usa l'origine del pod. Il relativo middleware evita il rifiuto
    # delle navigazioni cross-site osservato con l'avvio dalla console RunPod.
    ORIGINE_COMFY=http://127.0.0.1:8188
    if [ -n "${RUNPOD_POD_ID:-}" ]; then
      ORIGINE_COMFY="https://$RUNPOD_POD_ID-8188.proxy.runpod.net"
    fi
    log "Avvio ComfyUI sulla porta 8188. Dettagli in $LOG_COMFY"
    (
      cd "$C"
      exec nohup "$PY" -u main.py --listen 0.0.0.0 --port 8188 \
        --enable-cors-header "$ORIGINE_COMFY" 9>&- >> "$LOG_COMFY" 2>&1 < /dev/null
    ) &
    PID_COMFY=$!
    printf '%s\n' "$PID_COMFY" > "$FILE_PID"
  fi

  # Il primo avvio gia misurato impiegava alcuni minuti per caricare i nodi.
  # Jupyter rimane disponibile durante l'attesa.
  local scadenza_itaca=$((SECONDS + 900))
  while (( SECONDS < scadenza_itaca )); do
    if comfy_risponde; then
      log "Workflow pronto e ComfyUI raggiungibile sulla porta 8188."
      log "Preparazione completata in $((SECONDS - INIZIO_ITACA)) secondi."
      return
    fi
    if ! kill -0 "$PID_COMFY" 2>/dev/null; then
      log "ComfyUI si e' fermato. Ultime righe del log:"
      tail -n 60 "$LOG_COMFY"
      return 1
    fi
    sleep 2
  done
  log "ComfyUI non e' ancora raggiungibile. Controlla $LOG_COMFY."
  log "Se il processo e' ancora in avvio, ripetere il comando ne attende il completamento."
  return 1
}

