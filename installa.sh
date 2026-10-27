#!/usr/bin/env bash
# ITACA - installa ComfyUI, nodi e librerie sul pod RunPod (Task 3 del provisioner, 2026-10-27).
# Lo lancia avvio.sh. Si può rieseguire: salta ciò che è già installato alla versione giusta.
set -euo pipefail

W=/workspace
P=$W/provisioner
C=$W/ComfyUI
N=$C/custom_nodes
V=$W/venv
PY=$V/bin/python

export UV_LINK_MODE=copy                   # cache di uv sul container disk, venv su /workspace
export UV_PYTHON_INSTALL_DIR=$W/.uv-python # se uv scarica Python, resta su /workspace

log() { echo "[ITACA $(date +%H:%M:%S)] $*"; }

# 1. Driver: l'host deve supportare CUDA 12.8 o superiore (PyTorch cu128).
CUDA_DRV=$(nvidia-smi | sed -n 's/.*CUDA Version: \([0-9][0-9.]*\).*/\1/p' | head -n1)
if [ -z "$CUDA_DRV" ] || [ "$(printf '%s\n' 12.8 "$CUDA_DRV" | sort -V | head -n1)" != "12.8" ]; then
  log "ERRORE: CUDA del driver '$CUDA_DRV' sotto 12.8. Termina il pod e prendine un altro."
  exit 1
fi
log "Driver ok: CUDA $CUDA_DRV"

# 2. Ambiente Python 3.13 (stessa minor della portable).
if [ ! -x "$PY" ]; then
  log "Creo il venv Python 3.13"
  uv venv --python 3.13 "$V"
fi

# 3. Repository git a un commit fisso.
clona() {
  local dir=$1 url=$2 commit=$3
  if [ ! -d "$dir/.git" ]; then
    log "Clono $url"
    git clone --quiet "$url" "$dir"
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
    git -C "$dir" fetch --quiet origin
    git -C "$dir" checkout --quiet "$commit"
  fi
  log "$(basename "$dir") al commit ${commit:0:7}"
}

clona "$C" https://github.com/Comfy-Org/ComfyUI 483dae4326356b81de05d27aca3f433dd323cc25   # 0.42.5

# 4. Nodi installati con git nella portable.
clona "$N/ComfyUI-LTXVideo"             https://github.com/Lightricks/ComfyUI-LTXVideo             220e1d45aa0469f518e982102fca4dca92a61862
clona "$N/ComfyUI-Video-Depth-Anything" https://github.com/yuvraj108c/ComfyUI-Video-Depth-Anything a0db08e63d1ea571601c45cde4aaee0acdd0544d
clona "$N/ComfyUI-VideoHelperSuite"     https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite    4d907bee61e92c2e65af3bd6383a4e4d356126d1
clona "$N/ComfyUI-KJNodes"              https://github.com/kijai/ComfyUI-KJNodes                   d3cfe21625e5170126ce06fbfcfe1d88108688c3

# 5. Nodi installati dal Comfy Registry nella portable: stesso archivio della versione installata.
registry() {
  local dir=$1 url=$2 dest=$N/$1 tmp sub
  if [ -f "$dest/.itaca_versione" ] && [ "$(cat "$dest/.itaca_versione")" = "$url" ]; then
    log "$dir già installato"
    return
  fi
  log "Scarico $dir"
  rm -rf "$dest"
  mkdir -p "$dest"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/archivio"
  case "$url" in
    *.zip)    "$PY" -m zipfile -e "$tmp/archivio" "$dest" ;;
    *.tar.gz) tar -xzf "$tmp/archivio" -C "$dest" ;;
    *)        log "ERRORE: formato sconosciuto $url"; exit 1 ;;
  esac
  rm -rf "$tmp"
  if [ ! -f "$dest/__init__.py" ]; then   # archivio con una cartella in cima: sposto il contenuto su
    sub=$(find "$dest" -mindepth 2 -maxdepth 2 -name __init__.py | head -n1)
    if [ -n "$sub" ]; then
      shopt -s dotglob
      mv "$(dirname "$sub")"/* "$dest"/
      rmdir "$(dirname "$sub")"
      shopt -u dotglob
    fi
  fi
  if [ ! -f "$dest/__init__.py" ]; then
    log "ERRORE: $dir senza __init__.py"
    exit 1
  fi
  echo "$url" > "$dest/.itaca_versione"
}

registry rgthree-comfy                 https://cdn.comfy.org/rgthree/rgthree-comfy/1.0.2608312342/node.zip
registry comfyui_essentials            https://cdn.comfy.org/matteo/comfyui_essentials/1.1.0/node.tar.gz
registry comfyui_controlnet_aux        https://cdn.comfy.org/fannovel16/comfyui_controlnet_aux/1.1.5/node.zip
registry comfyui-impact-pack           https://cdn.comfy.org/drltdata/comfyui-impact-pack/8.28.3/node.zip
registry comfyui-inpaint-cropandstitch https://cdn.comfy.org/lquesada/comfyui-inpaint-cropandstitch/3.0.16/node.zip
registry ComfyUI-EasyColorCorrector    https://cdn.comfy.org/itsjustregi/ComfyUI-EasyColorCorrector/1.2.5/node.zip
registry comfyui-mute-bypass-by-ID     https://cdn.comfy.org/pixelpainter/comfyui-mute-bypass-by-ID/3.0.3/node.zip

# 6. Librerie: dal lock se c'è, altrimenti da requirements.in e salvo il lock.
if [ -f "$P/requirements.lock" ]; then
  log "Installo le librerie da requirements.lock"
  uv pip sync --python "$PY" --torch-backend cu128 "$P/requirements.lock"
else
  log "Installo le librerie da requirements.in (primo pod, nessun lock)"
  uv pip install --python "$PY" --torch-backend cu128 -r "$P/requirements.in"
  uv pip freeze --python "$PY" > "$W/requirements.lock"
  log "Lock creato: $W/requirements.lock. Scaricalo e caricalo nel repository."
fi

log "Installazione completata"
