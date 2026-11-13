"""Itaca nodes - nodi di Itacajutsu per ComfyUI.

Itaca Latent Protetto (lancio 5 del collaudo, stadio 1 di Itacajutsu)
--------------------------------------------------------------------
Protegge nel latent tutto cio' che sta fuori dalla zona rigenerabile:
- fuori dalla zona i valori del latent diventano quelli del render codificato col VAE;
- la noise_mask vale 0 fuori dalla zona (il modello conserva) e 1 dentro (il modello rigenera).

Va messo DOPO le guide IC-LoRA e PRIMA del campionatore, in entrambi gli stadi:
tocca solo i primi frame del latent (il video) e lascia invariati quelli
aggiunti in coda dalle guide.

Controllo della lunghezza (versione del 2026-11-06): dal conditioning positive
dell'ultima guida legge quanti frame delle guide sono in coda al latent, con la
stessa funzione che usa LTXVCropGuides per toglierle dopo il campionamento, e si
ferma con un errore se il video nel latent non ha la lunghezza della sorgente.

La maschera in pixel (1 = rigenera) si porta sulla griglia dei token LTX:
- nel tempo per gruppi causali del VAE: frame 0 da solo, poi gruppi da 8, con il massimo del gruppo;
- nello spazio con il massimo su ogni cella del latent (32 px della misura dello stadio).

In bypass il nodo lascia passare il latent in arrivo senza modifiche.
"""

import torch
import torch.nn.functional as F
from typing_extensions import override

import comfy_extras.nodes_lt as nodes_lt
from comfy_api.latest import ComfyExtension, io

FATTORE_TEMPORALE = 8  # VAE video LTX: il frame 0 da solo, poi un frame latent ogni 8 frame


def maschera_per_token(maschera, frame_latent, altezza, larghezza):
    """Porta una maschera [N, H, W] in pixel sulla griglia [frame_latent, altezza, larghezza]."""
    if maschera.dim() == 2:
        maschera = maschera.unsqueeze(0)
    maschera = maschera.float()
    attesi = 1 + (frame_latent - 1) * FATTORE_TEMPORALE
    if maschera.shape[0] == 1 and attesi > 1:
        maschera = maschera.expand(attesi, -1, -1)
    if maschera.shape[0] != attesi:
        raise ValueError(
            f"Itaca Latent Protetto: la maschera ha {maschera.shape[0]} frame, "
            f"ma per {frame_latent} frame latent ne servono {attesi}."
        )
    gruppi = [maschera[0]]
    for t in range(1, frame_latent):
        inizio = 1 + (t - 1) * FATTORE_TEMPORALE
        gruppi.append(maschera[inizio:inizio + FATTORE_TEMPORALE].amax(dim=0))
    per_frame = torch.stack(gruppi, dim=0).unsqueeze(1)          # [F, 1, H, W]
    per_token = F.adaptive_max_pool2d(per_frame, (altezza, larghezza))  # [F, 1, h, w]
    return per_token.squeeze(1).clamp(0.0, 1.0)                 # [F, h, w]


class ItacaLatentProtetto(io.ComfyNode):
    @classmethod
    def define_schema(cls):
        return io.Schema(
            node_id="ItacaLatentProtetto",
            display_name="Itaca Latent Protetto",
            category="Itaca/latent",
            description=(
                "Conserva il render fuori dalla zona rigenerabile: sostituisce il latent con quello del render "
                "e imposta la noise_mask per token (0 conserva, 1 rigenera). Va dopo le guide e prima del campionatore."
            ),
            inputs=[
                io.Latent.Input(
                    "latent",
                    tooltip="Latent in arrivo, gia' con le guide in coda. Passa invariato se il nodo e' in bypass.",
                ),
                io.Latent.Input(
                    "latent_sorgente",
                    tooltip="Render codificato col VAE alla misura di questo stadio, senza guide.",
                ),
                io.Mask.Input(
                    "maschera",
                    tooltip="Zona rigenerabile in pixel (1 = rigenera), stessi frame del video.",
                ),
                io.Conditioning.Input(
                    "positive",
                    tooltip=(
                        "Positive in uscita dall'ultima guida, lo stesso che va al campionatore: "
                        "serve a contare i frame delle guide in coda al latent."
                    ),
                ),
            ],
            outputs=[io.Latent.Output()],
        )

    @classmethod
    def execute(cls, latent, latent_sorgente, maschera, positive) -> io.NodeOutput:
        campioni = latent["samples"]
        sorgente = latent_sorgente["samples"].to(device=campioni.device, dtype=campioni.dtype)

        if campioni.dim() != 5 or sorgente.dim() != 5:
            raise ValueError("Itaca Latent Protetto: servono latent video a 5 dimensioni.")
        b, c, frame_video, h, w = sorgente.shape
        if campioni.shape[0] != b or campioni.shape[1] != c or tuple(campioni.shape[3:]) != (h, w):
            raise ValueError(
                f"Itaca Latent Protetto: latent {tuple(campioni.shape)} e sorgente {tuple(sorgente.shape)} "
                "non hanno la stessa misura. Controlla che la sorgente sia codificata alla misura di questo stadio."
            )

        # Frame delle guide in coda: stessa funzione di LTXVCropGuides (comfy_extras/nodes_lt.py).
        _, frame_guide = nodes_lt.get_keyframe_idxs(positive, campioni.shape)
        frame_latent_video = campioni.shape[2] - frame_guide
        if frame_latent_video != frame_video:
            raise ValueError(
                f"Itaca Latent Protetto: il video nel latent ha {frame_latent_video} frame latent "
                f"({campioni.shape[2]} in tutto, {frame_guide} delle guide in coda), la sorgente ne ha {frame_video}. "
                "Controlla che sorgente, guida e maschera vengano dallo stesso clip e che positive "
                "arrivi dall'ultima guida prima del campionatore."
            )

        token = maschera_per_token(maschera.to(campioni.device), frame_video, h, w)
        m = token.to(campioni.dtype).view(1, 1, frame_video, h, w)

        nuovi = campioni.clone()
        nuovi[:, :, :frame_video] = sorgente * (1.0 - m) + campioni[:, :, :frame_video] * m

        frame_totali = campioni.shape[2]
        esistente = latent.get("noise_mask", None)
        if esistente is None:
            esistente = torch.ones((b, 1, frame_totali, 1, 1), dtype=torch.float32, device=campioni.device)
        esistente = esistente.to(device=campioni.device, dtype=torch.float32)
        if tuple(esistente.shape[3:]) == (1, 1):
            esistente = esistente.expand(-1, -1, -1, h, w)
        elif tuple(esistente.shape[3:]) != (h, w):
            esistente = F.interpolate(esistente, size=(esistente.shape[2], h, w), mode="nearest")
        noise_mask = esistente.clone()
        noise_mask[:, :, :frame_video] = m.float().expand(b, -1, -1, -1, -1)

        uscita = latent.copy()
        uscita["samples"] = nuovi
        uscita["noise_mask"] = noise_mask
        return io.NodeOutput(uscita)


class ItacaExtension(ComfyExtension):
    @override
    async def get_node_list(self) -> list[type[io.ComfyNode]]:
        return [ItacaLatentProtetto]


async def comfy_entrypoint() -> ItacaExtension:
    return ItacaExtension()
