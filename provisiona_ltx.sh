#!/usr/bin/env bash
# ITACA - il workflow LTX Layout to Render. 2026-10-28.
set -Eeuo pipefail
source "$(dirname -- "$0")/comune.sh"

prepara_ambiente
log "Preparo il workflow LTX Layout to Render"
scarica "Lightricks/LTX-2.5" "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors" "$C/models/diffusion_models"
scarica "Lightricks/LTX-2.5" "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors" "$C/models/text_encoders"
scarica "Lightricks/LTX-2.5" "vae/ltx-2.5-video-vae-bf16.safetensors" "$C/models/vae"
scarica "Lightricks/LTX-2.5" "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors" "$C/models/latent_upscale_models"
scarica "Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render" "ltx-2.5-22b-ic-lora-layout-to-render-1.0.safetensors" "$C/models/loras"
scarica "Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control" "ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors" "$C/models/loras"
scarica "depth-anything/Video-Depth-Anything-Small" "video_depth_anything_vits.pth" "$C/models/videodepthanything"
workflow LTX_LAYOUT_2_RENDER.json
avvia_comfy

