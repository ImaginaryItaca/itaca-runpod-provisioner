"""ITACA - scarica tutti i pesi dei workflow Itaca sul pod RunPod (Task 4 del provisioner, 2026-10-27).

Lo lancia avvio.sh con il Python del venv. Si può rieseguire: salta i file già presenti con la dimensione giusta e
riprende i download interrotti. Usa il token HF_TOKEN del template (segreto RunPod hf_token).
Dimensioni lette dalle API di Hugging Face il 2026-10-27: se un file cambia sul repository, il controllo lo segnala.
"""
import os
import pathlib
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

from huggingface_hub import hf_hub_download

W = pathlib.Path("/workspace")
M = "ComfyUI/models"
AUX = "aux_ckpts"  # pesi dei preprocessori di controlnet_aux (avvio.sh imposta AUX_ANNOTATOR_CKPTS_PATH qui)

# (repository, file nel repository, cartella di destinazione sotto /workspace, byte attesi o None)
PESI = [
    # --- LTX Layout to Render (C1) ---
    ("Lightricks/LTX-2.5", "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors",
     f"{M}/diffusion_models", 42018190584),
    ("Lightricks/LTX-2.5", "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors",
     f"{M}/text_encoders", 26263858182),
    ("Lightricks/LTX-2.5", "vae/ltx-2.5-video-vae-bf16.safetensors",
     f"{M}/vae", 1472223346),
    ("Lightricks/LTX-2.5", "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors",
     f"{M}/latent_upscale_models", 995778752),
    ("Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render", "ltx-2.5-22b-ic-lora-layout-to-render-1.0.safetensors",
     f"{M}/loras", 1308787439),
    ("Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control", "ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors",
     f"{M}/loras", 654465352),
    ("depth-anything/Video-Depth-Anything-Small", "video_depth_anything_vits.pth",
     f"{M}/videodepthanything", 116440756),
    # --- Keyframe Qwen-Image-Edit-2511 ---
    ("Comfy-Org/Qwen-Image-Edit_ComfyUI", "split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors",
     f"{M}/diffusion_models", 40861031560),
    ("Comfy-Org/Qwen-Image_ComfyUI", "split_files/text_encoders/qwen_2.5_vl_7b.safetensors",
     f"{M}/text_encoders", 16584415576),
    ("Comfy-Org/Qwen-Image_ComfyUI", "split_files/vae/qwen_image_vae.safetensors",
     f"{M}/vae", 253806246),
    ("alibaba-pai/Qwen-Image-2512-Fun-Controlnet-Union", "Qwen-Image-2512-Fun-Controlnet-Union-2602.safetensors",
     f"{M}/controlnet", 3512432536),
    # --- Preprocessori di controlnet_aux: percorso <cartella>/<repository>/<file>, come custom_hf_download ---
    ("depth-anything/Depth-Anything-V2-Small", "depth_anything_v2_vits.pth",
     f"{AUX}/depth-anything/Depth-Anything-V2-Small", None),
    ("lllyasviel/Annotators", "ControlNetHED.pth", f"{AUX}/lllyasviel/Annotators", None),
    ("lllyasviel/Annotators", "mlsd_large_512_fp32.pth", f"{AUX}/lllyasviel/Annotators", None),
    ("hr16/yolox-onnx", "yolox_l.torchscript.pt", f"{AUX}/hr16/yolox-onnx", None),
    ("hr16/DWPose-TorchScript-BatchSize5", "dw-ll_ucoco_384_bs5.torchscript.pt",
     f"{AUX}/hr16/DWPose-TorchScript-BatchSize5", None),
]

MARGINE = 20 * 1024**3  # spazio libero da lasciare sul disco dopo i download (uscite, venv, cache)


def log(testo):
    print(f"[ITACA {time.strftime('%H:%M:%S')}] {testo}", flush=True)


def destinazione(voce):
    _, nome, cartella, _ = voce
    return W / cartella / pathlib.PurePosixPath(nome).name


def presente(voce):
    dest = destinazione(voce)
    return dest.exists() and (voce[3] is None or dest.stat().st_size == voce[3])


def scarica(voce):
    repo, nome, _, byte = voce
    dest = destinazione(voce)
    inizio = time.time()
    percorso = hf_hub_download(repo_id=repo, filename=nome, local_dir=W / ".scaricamenti" / repo)
    dest.parent.mkdir(parents=True, exist_ok=True)
    os.replace(percorso, dest)  # stesso disco: spostamento immediato, nessuna copia
    if byte is not None and dest.stat().st_size != byte:
        raise RuntimeError(f"{dest.name}: {dest.stat().st_size} byte invece di {byte}")
    return f"scaricato {dest.name} in {time.time() - inizio:.0f} s"


def main():
    if not os.environ.get("HF_TOKEN"):
        log("ATTENZIONE: HF_TOKEN vuoto, i repository LTX gated daranno errore 403")
    da_scaricare = [v for v in PESI if not presente(v)]
    if not da_scaricare:
        log("Pesi: tutti presenti")
        return 0
    servono = sum(v[3] or 0 for v in da_scaricare)
    libero = shutil.disk_usage(W).free
    if libero < servono + MARGINE:
        log(f"ERRORE: servono {servono / 1e9:.0f} GB più {MARGINE / 1024**3:.0f} GB di margine, "
            f"liberi {libero / 1e9:.0f} GB. Aumenta il volume del pod.")
        return 1
    log(f"Pesi: {len(da_scaricare)} file da scaricare, circa {servono / 1e9:.0f} GB")
    inizio = time.time()
    errori = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        lavori = {pool.submit(scarica, v): v for v in da_scaricare}
        for lavoro in as_completed(lavori):
            try:
                log(lavoro.result())
            except Exception as e:
                errori += 1
                log(f"ERRORE {lavori[lavoro][0]}/{lavori[lavoro][1]}: {e}")
    log(f"Pesi: finito in {(time.time() - inizio) / 60:.1f} minuti, errori {errori}")
    return 1 if errori else 0


if __name__ == "__main__":
    sys.exit(main())
