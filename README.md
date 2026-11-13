# Provisioner Itaca per i workflow Qwen e LTX

13 novembre 2026. ComfyUI 0.44.2, come la portable.

## Che cosa preparano

| Comando | Pesi | Workflow |
|---|---|---|
| provisiona_qwen.sh | Qwen-Image-Edit 2511, encoder Qwen 2.5 VL 7B, VAE Qwen; ControlNet Union 2602 e 5 pesi dei preprocessori (rami in bypass) | QWEN_EDIT.json |
| provisiona_ltx.sh | LTX-2.5 distilled, Gemma 4 12B, VAE video, upscaler x2; LoRA Layout to Render e Alpha Gen; LoRA Union Control e Video Depth Anything (ramo DEPTH in bypass) | LTX_LAYOUT_2_RENDER.json |

La base è comune e si prepara una volta per pod:

- ComfyUI 0.44.2 (commit e6515b16ed360b01bd6548bffaca193f88f181fb), Python 3.13, PyTorch 2.10.0 cu128, librerie a versione fissa;
- 9 pacchetti di nodi: LTXVideo, Video Depth Anything, VideoHelperSuite e KJNodes da Git; rgthree, essentials, controlnet_aux e mute-bypass-by-ID dal Registry; itaca_nodes da questo repository.

Entrambi i comandi scaricano anche i render del dataset indicato in `DATASET` (comune.sh) nella radice di `ComfyUI/input`, con i nomi usati nei grafi. Nel dataset vanno solo i render 3D: reference e keyframe si caricano dai nodi.

## Contenuto del repository

- `comune.sh`, `provisiona_qwen.sh`, `provisiona_ltx.sh`: stanno insieme nella radice.
- `itaca_nodes/__init__.py`: nodo ItacaLatentProtetto (lancio 5).
- `Workflows/`: QWEN_EDIT.json e LTX_LAYOUT_2_RENDER.json, copiati sul pod in `user/default/workflows/ITACA`.

## Template ITACA-QWEN e ITACA-LTX

Stessa configurazione, cambia solo il Container start command:

- immagine `runpod/base:1.4.1-cuda1281-ubuntu2404`;
- container disk 40 GB; Volume disk 250 GB su `/workspace`, da aggiungere al deploy (la pagina non lo prende dal template);
- porte HTTP 8188 (ComfyUI) e 8888 (Jupyter);
- `HF_TOKEN={{ RUNPOD_SECRET_hf_token }}`: token di lettura di un account con accesso al dataset e ai repository gated (LTX-2.5, Layout to Render, Alpha Gen);
- `JUPYTER_PASSWORD={{ RUNPOD_SECRET_jupyter_password }}`.

ITACA-QWEN:

```bash
bash -c 'set -e; mkdir -p /workspace/provisioner; for file_itaca in comune.sh provisiona_qwen.sh provisiona_ltx.sh; do curl -fsSL --retry 3 "https://raw.githubusercontent.com/ImaginaryItaca/itaca-runpod-provisioner/refs/heads/main/$file_itaca" -o "/workspace/provisioner/$file_itaca.part"; bash -n "/workspace/provisioner/$file_itaca.part"; mv "/workspace/provisioner/$file_itaca.part" "/workspace/provisioner/$file_itaca"; done; printf "%s\n" "bash /workspace/provisioner/provisiona_qwen.sh || true" > /post_start.sh; exec bash /start.sh'
```

ITACA-LTX:

```bash
bash -c 'set -e; mkdir -p /workspace/provisioner; for file_itaca in comune.sh provisiona_qwen.sh provisiona_ltx.sh; do curl -fsSL --retry 3 "https://raw.githubusercontent.com/ImaginaryItaca/itaca-runpod-provisioner/refs/heads/main/$file_itaca" -o "/workspace/provisioner/$file_itaca.part"; bash -n "/workspace/provisioner/$file_itaca.part"; mv "/workspace/provisioner/$file_itaca.part" "/workspace/provisioner/$file_itaca"; done; printf "%s\n" "bash /workspace/provisioner/provisiona_ltx.sh || true" > /post_start.sh; exec bash /start.sh'
```

Il comando scarica i tre script, ne controlla la sintassi con `bash -n` e scrive `/post_start.sh`, che lancia il provisioner dopo l'avvio di Jupyter. Il pod resta attivo anche se il provisioner segnala un errore: l'esito si legge nel log.

## Aggiungere l'altro workflow a pod acceso

Dal terminale di Jupyter:

```bash
bash /workspace/provisioner/provisiona_ltx.sh
```

oppure `provisiona_qwen.sh`. Base, pesi e grafi già presenti vengono riusati; un secondo provisioner lanciato nello stesso momento attende il primo. Alla fine salva il lavoro aperto e ricarica la pagina di ComfyUI: la stessa istanza continua a funzionare.

## Grafi allineati

Il provisioner non sovrascrive un grafo già presente sul pod. Se modifichi un grafo sul pod, salvalo in locale e rimettilo in `Workflows/`: il prossimo pod nuovo riceverà quello.

## Primo avvio: cosa controllare

1. `/workspace/provision.log`: account in `hf auth whoami`, download completati, "ComfyUI raggiungibile sulla porta 8188".
2. `/system_stats` di ComfyUI: versione 0.44.2, frontend 1.57.6.
3. I due grafi si aprono senza nodi mancanti.
4. Il secondo provisioner usa la stessa istanza di ComfyUI.

## Accesso dal browser

ComfyUI parte con `--enable-cors-header` sull'origine del pod (`https://<RUNPOD_POD_ID>-8188.proxy.runpod.net`). Con questa opzione ComfyUI 0.44.2 non usa il controllo che rifiuta con 403 le navigazioni cross-site (server.py). Se il browser dà ancora 403, dal terminale:

```bash
curl -s -o /dev/null -w 'ComfyUI cross-site: %{http_code}\n' -H 'Sec-Fetch-Site: cross-site' http://127.0.0.1:8188/
```

Se risponde 200, il rifiuto viene da fuori ComfyUI.

## Log e uscite

- Preparazione e download: `/workspace/provision.log`. ComfyUI: `/workspace/comfyui.log`. Jupyter: `/jupyter.log`.
- Le uscite si scaricano da JupyterLab prima del Terminate: il Volume disk si cancella con il pod.

## Manutenzione

- Ogni modifica della base (ComfyUI, pacchetti, librerie, itaca_nodes) richiede un nuovo `MARCATORE_BASE` in comune.sh, altrimenti un pod fermato e riavviato tiene la base vecchia.
- Il dataset di un altro shot si indica in `DATASET`.
