#!/usr/bin/env bash
# ITACA - il workflow keyframe Qwen. 2026-10-28.
set -Eeuo pipefail
source "$(dirname -- "$0")/comune.sh"

prepara_ambiente
log "Preparo il workflow keyframe Qwen"
scarica "Comfy-Org/Qwen-Image-Edit" "split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors" "$C/models/diffusion_models"
scarica "Comfy-Org/Qwen-Image" "split_files/text_encoders/qwen_2.5_vl_7b.safetensors" "$C/models/text_encoders"
scarica "Comfy-Org/Qwen-Image" "split_files/vae/qwen_image_vae.safetensors" "$C/models/vae"
scarica "alibaba-pai/Qwen-Image-2512-Fun-Controlnet-Union" "Qwen-Image-2512-Fun-Controlnet-Union-2602.safetensors" "$C/models/controlnet"
scarica "depth-anything/Depth-Anything-V2-Small" "depth_anything_v2_vits.pth" "$AUX_ANNOTATOR_CKPTS_PATH/depth-anything/Depth-Anything-V2-Small"
scarica "lllyasviel/Annotators" "ControlNetHED.pth" "$AUX_ANNOTATOR_CKPTS_PATH/lllyasviel/Annotators"
scarica "lllyasviel/Annotators" "mlsd_large_512_fp32.pth" "$AUX_ANNOTATOR_CKPTS_PATH/lllyasviel/Annotators"
scarica "hr16/yolox-onnx" "yolox_l.torchscript.pt" "$AUX_ANNOTATOR_CKPTS_PATH/hr16/yolox-onnx"
scarica "hr16/DWPose-TorchScript-BatchSize5" "dw-ll_ucoco_384_bs5.torchscript.pt" "$AUX_ANNOTATOR_CKPTS_PATH/hr16/DWPose-TorchScript-BatchSize5"
workflow KEYFRAME_QWEN_EDIT_2511_LTX.json
avvia_comfy

