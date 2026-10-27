#!/usr/bin/env bash
# ITACA - prepara ComfyUI sul pod e lo avvia. 2026-10-27.
# Immagine: runpod/base:1.4.1-cuda1281-ubuntu2404.
# Installazione iniziale: ComfyUI 0.42.5, 11 pacchetti di nodi, 16 pesi, 2 workflow.
# Lo script viene eseguito come /post_start.sh dall'avvio ufficiale RunPod.
# Sullo stesso pod riusa i pesi completati e preserva i workflow gia presenti.
set -Eeuo pipefail

W=/workspace
C=$W/ComfyUI
N=$C/custom_nodes
PY=$W/venv/bin/python
HF=$W/venv/bin/hf
WF=$C/user/default/workflows/Itaca
SORGENTE=https://raw.githubusercontent.com/ImaginaryItaca/itaca-runpod-provisioner/refs/heads/main

mkdir -p "$W"
exec > >(tee -a "$W/provision.log") 2>&1
log() { echo "[ITACA $(date +%H:%M:%S)] $*"; }
trap 'stato_itaca=$?; echo "[ITACA] ERRORE alla riga $LINENO (codice $stato_itaca). Preparazione interrotta." >&2; exit "$stato_itaca"' ERR

# Il token arriva dal segreto RunPod. Non serve hf auth login.
test -n "${HF_TOKEN:-}" || { log "HF_TOKEN assente nel template"; exit 1; }

# Python, librerie, cache e modelli restano sul volume del pod.
export UV_PYTHON_INSTALL_DIR=$W/.uv-python
export UV_CACHE_DIR=$W/.cache/uv
export HF_HOME=$W/.cache/huggingface
export AUX_ANNOTATOR_CKPTS_PATH=$W/aux_ckpts
# In hub 0.36.2 hf_transfer impedisce la ripresa dei parziali HTTP. Xet resta disponibile.
export HF_HUB_ENABLE_HF_TRANSFER=0
export HF_XET_CHUNK_CACHE_SIZE_BYTES=0

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

# Il client ufficiale HF scarica in una cartella di lavoro sullo stesso volume.
# Solo dopo il successo del comando il file completo entra nella cartella del modello.
# I parziali restano dove HF puo riprenderli al prossimo avvio.
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

log "Scarico gli 11 pesi principali e i 5 pesi ausiliari"
scarica "Lightricks/LTX-2.5" "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors" "$C/models/diffusion_models"
scarica "Lightricks/LTX-2.5" "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors" "$C/models/text_encoders"
scarica "Lightricks/LTX-2.5" "vae/ltx-2.5-video-vae-bf16.safetensors" "$C/models/vae"
scarica "Lightricks/LTX-2.5" "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors" "$C/models/latent_upscale_models"
scarica "Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render" "ltx-2.5-22b-ic-lora-layout-to-render-1.0.safetensors" "$C/models/loras"
scarica "Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control" "ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors" "$C/models/loras"
scarica "depth-anything/Video-Depth-Anything-Small" "video_depth_anything_vits.pth" "$C/models/videodepthanything"
scarica "Comfy-Org/Qwen-Image-Edit" "split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors" "$C/models/diffusion_models"
scarica "Comfy-Org/Qwen-Image" "split_files/text_encoders/qwen_2.5_vl_7b.safetensors" "$C/models/text_encoders"
scarica "Comfy-Org/Qwen-Image" "split_files/vae/qwen_image_vae.safetensors" "$C/models/vae"
scarica "alibaba-pai/Qwen-Image-2512-Fun-Controlnet-Union" "Qwen-Image-2512-Fun-Controlnet-Union-2602.safetensors" "$C/models/controlnet"
scarica "depth-anything/Depth-Anything-V2-Small" "depth_anything_v2_vits.pth" "$AUX_ANNOTATOR_CKPTS_PATH/depth-anything/Depth-Anything-V2-Small"
scarica "lllyasviel/Annotators" "ControlNetHED.pth" "$AUX_ANNOTATOR_CKPTS_PATH/lllyasviel/Annotators"
scarica "lllyasviel/Annotators" "mlsd_large_512_fp32.pth" "$AUX_ANNOTATOR_CKPTS_PATH/lllyasviel/Annotators"
scarica "hr16/yolox-onnx" "yolox_l.torchscript.pt" "$AUX_ANNOTATOR_CKPTS_PATH/hr16/yolox-onnx"
scarica "hr16/DWPose-TorchScript-BatchSize5" "dw-ll_ucoco_384_bs5.torchscript.pt" "$AUX_ANNOTATOR_CKPTS_PATH/hr16/DWPose-TorchScript-BatchSize5"

# I workflow modificati e salvati sul pod vengono preservati ai riavvii.
workflow() {
  local nome=$1
  if [ -f "$WF/$nome" ]; then
    log "Workflow gia presente: $nome"
    return
  fi
  curl -fL --retry 3 "$SORGENTE/Workflows/$nome" -o "$WF/$nome.part"
  "$PY" -m json.tool "$WF/$nome.part" > /dev/null
  mv "$WF/$nome.part" "$WF/$nome"
}
log "Copio i due workflow Itaca"
mkdir -p "$WF" "$C/input" "$C/output"
workflow KEYFRAME_QWEN_EDIT_2511_LTX.json
workflow LTX_LAYOUT_2_RENDER.json

log "Preparazione completata. Avvio ComfyUI sulla porta 8188."
log "Il servizio sara accessibile quando ComfyUI avra terminato il caricamento dei nodi."
cd "$C"
exec "$PY" main.py --listen 0.0.0.0 --port 8188
