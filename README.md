# Provisioner Itaca per i due workflow attuali

28 ottobre 2026. Consegna da copiare nel repository; prova sul pod ancora da eseguire.

## Che cosa preparano

| Comando | Pesi scaricati | Workflow |
|---|---|---|
| provisiona_qwen.sh | 4 principali Qwen e 5 ausiliari dei preprocessori | KEYFRAME_QWEN_EDIT_2511_LTX.json |
| provisiona_ltx.sh | 7 pesi LTX, LoRA, upscaler e Video Depth Anything | LTX_LAYOUT_2_RENDER.json |

Inferenza: per semplificare il passaggio tra i due, la base gia provata resta comune: ComfyUI 0.42.5, Python 3.13, PyTorch 2.10.0 cu128, librerie e tutti gli 11 pacchetti di nodi. Si prepara una sola volta. Ogni comando scarica soltanto i pesi del proprio workflow e copia quel JSON.

Questo riduce il download iniziale. Il primo comando deve comunque preparare la base completa; il secondo riutilizza quella base senza installare o aggiornare librerie mentre ComfyUI lavora. Non abbiamo ancora misurato il nuovo tempo di avvio.

Si possono usare in entrambi gli ordini, sullo stesso pod. Non serve un nuovo login HF: viene usato il segreto del template.

## File da copiare nel repository

Copia nella radice di ImaginaryItaca/itaca-runpod-provisioner:

- comune.sh
- provisiona_qwen.sh
- provisiona_ltx.sh
- questo LEGGIMI, facoltativo per l'esecuzione.

I due JSON restano nella cartella Workflows/ con i nomi attuali. I nuovi comandi sostituiscono l'uso di avvio_itaca.sh; il vecchio file non e' piu richiamato dal template dopo la modifica qui sotto. Questi script riguardano il template ITACA su immagine base, non il template ComfyUI preinstallato.

I tre script devono stare insieme. Caricali e conferma il commit prima di avviare il pod.

## Template ITACA: scegliere il primo workflow

Configurazione gia usata:

- Immagine: `runpod/base:1.4.1-cuda1281-ubuntu2404`.
- Container disk: 40 GB; Volume disk: 250 GB, montato su `/workspace`.
- Porte HTTP: 8188 per ComfyUI, 8888 per Jupyter.
- `HF_TOKEN={{ RUNPOD_SECRET_hf_token }}`.
- `JUPYTER_PASSWORD={{ RUNPOD_SECRET_jupyter_password }}`.

Nel campo Container start command incolla UNO dei due comandi completi. Entrambi portano sul pod i tre script, controllano la sintassi Bash e mantengono l'avvio Jupyter nativo di RunPod. Il comando del post-start conserva il pod e Jupyter anche se il provisioner segnala un errore: il successo va verificato nel log, non dal solo stato Running del pod.

### Partire dai keyframe Qwen

```bash
bash -c 'set -e; mkdir -p /workspace/provisioner; for file_itaca in comune.sh provisiona_qwen.sh provisiona_ltx.sh; do curl -fsSL --retry 3 "https://raw.githubusercontent.com/ImaginaryItaca/itaca-runpod-provisioner/refs/heads/main/$file_itaca" -o "/workspace/provisioner/$file_itaca.part"; bash -n "/workspace/provisioner/$file_itaca.part"; mv "/workspace/provisioner/$file_itaca.part" "/workspace/provisioner/$file_itaca"; done; printf "%s\n" "bash /workspace/provisioner/provisiona_qwen.sh || true" > /post_start.sh; exec bash /start.sh'
```

### Partire da LTX

```bash
bash -c 'set -e; mkdir -p /workspace/provisioner; for file_itaca in comune.sh provisiona_qwen.sh provisiona_ltx.sh; do curl -fsSL --retry 3 "https://raw.githubusercontent.com/ImaginaryItaca/itaca-runpod-provisioner/refs/heads/main/$file_itaca" -o "/workspace/provisioner/$file_itaca.part"; bash -n "/workspace/provisioner/$file_itaca.part"; mv "/workspace/provisioner/$file_itaca.part" "/workspace/provisioner/$file_itaca"; done; printf "%s\n" "bash /workspace/provisioner/provisiona_ltx.sh || true" > /post_start.sh; exec bash /start.sh'
```

Il primo workflow e' selezionato dalla riga che scrive /post_start.sh. L'altro comando rimane gia disponibile nel terminale Jupyter.

## Aggiungere o riutilizzare un workflow a pod acceso

Per preparare LTX:

```bash
bash /workspace/provisioner/provisiona_ltx.sh
```

Per preparare il keyframe Qwen:

```bash
bash /workspace/provisioner/provisiona_qwen.sh
```

Puoi lanciare il secondo mentre lavori con il primo. I file gia completati vengono saltati. I download parziali si riprendono attraverso il client HF. Un secondo provisioner lanciato contemporaneamente attende che il primo termini.

Quando il comando conferma che pesi e workflow sono pronti, salva il workflow aperto e ricarica la pagina di ComfyUI: l'altro workflow e i nuovi modelli saranno disponibili. La stessa istanza ComfyUI continua a funzionare; i pesi non vengono caricati tutti nella GPU.

I workflow gia presenti sul pod vengono preservati. Il JSON originale del keyframe lascia vuoto il ControlNetLoader 247: se attivi quel ramo, seleziona Qwen-Image-2512-Fun-Controlnet-Union-2602.safetensors, che il relativo provisioner scarica gia. Non vengono modificati grafo, preview o comportamento di esportazione.

Sul riavvio dello stesso pod i file in /workspace vengono riutilizzati. Un pod nuovo riparte dall'installazione e dai download del primo workflow scelto.

## Accesso dal browser normale

ComfyUI viene avviato con `--enable-cors-header` limitato all'origine HTTP del pod, ricavata da RUNPOD_POD_ID. In questo modo viene selezionata la gestione CORS senza il controllo che nella build 0.42.5 respinge una navigazione classificata cross-site. In assenza dell'identificativo RunPod l'origine usata e' http://127.0.0.1:8188.

Inferenza: questa modifica dovrebbe rimuovere il 403 di ComfyUI legato all'apertura dalla console RunPod. La causa del caso osservato non e' ancora confermata: manca una prova con il browser normale sul pod.

Jupyter continua a usare il suo avvio RunPod e il token corrispondente al segreto jupyter_password. La sua pagina di login e' prevista. Lo stato Initializing nella console va distinto dalla raggiungibilita effettiva.

Al prossimo avvio verifica soltanto la configurazione:

1. Apri Jupyter dal browser normale, accedi e apri un terminale.
2. Attendi nel log il messaggio che ComfyUI e' raggiungibile; prova sia il pulsante Connect sia lo stesso indirizzo incollato nella barra del browser.
3. Apri il primo workflow e controlla che non manchino pacchetti di nodi; gli input da fornire al workflow sono un controllo separato.
4. Esegui il comando dell'altro workflow, poi controllane presenza e modelli senza generare immagini o video.
5. Ripeti uno dei due comandi: deve riutilizzare base e pesi, mantenendo una sola istanza ComfyUI.

Se il browser normale da ancora 403, questo controllo dal terminale distingue il rifiuto di ComfyUI da un possibile problema a monte:

```bash
curl -s -o /dev/null -w 'ComfyUI cross-site: %{http_code}\n' -H 'Sec-Fetch-Site: cross-site' http://127.0.0.1:8188/
```

Con questa configurazione, dopo l'avvio il risultato atteso e' 200. Non dimostra da solo che proxy e cookie del browser funzionino: se all'esterno rimane il 403, annota quel caso prima di cambiare altro.

## Log e stato della verifica

- Preparazione e download: `/workspace/provision.log`, visibile anche nel terminale che esegue il comando.
- Avvio e messaggi di ComfyUI: `/workspace/comfyui.log`.
- Jupyter: `/jupyter.log`.

ComfyUI parte in background e il provisioner attende che risponda, fino a circa 15 minuti. Se il processo e' ancora in avvio alla scadenza, rimane attivo e un nuovo comando lo attende invece di avviarne un'altra copia. Se si ferma, Jupyter rimane disponibile e il log mostra l'errore.

Verificati staticamente: corrispondenza con i due JSON locali e con l'inventario, tutti i 16 download originali ripartiti una sola volta, conservazione dei 67 pin e degli 11 pacchetti, percorsi finali, riuso della base e gestione della stessa istanza ComfyUI. Non sono disponibili qui un interprete Bash/Linux o un pod attivo: bash -n viene eseguito automaticamente al bootstrap, mentre installazione, accesso dal browser e passaggio tra workflow restano da provare sul pod.

SkyReels resta fuori da questa consegna: il perimetro corretto per l'aggiunta futura e' un solo workflow con due modelli.

Fonti: [avvio base RunPod 1.4.1](https://github.com/runpod/containers/blob/base-v1.4.1/container-template/start.sh), [gestione del 403 in ComfyUI](https://github.com/Comfy-Org/ComfyUI/blob/483dae4326356b81de05d27aca3f433dd323cc25/server.py), [caso cross-site riportato](https://github.com/Comfy-Org/ComfyUI/issues/16203), [opzione CORS](https://github.com/Comfy-Org/ComfyUI/blob/483dae4326356b81de05d27aca3f433dd323cc25/comfy/cli_args.py), [variabili RunPod](https://docs.runpod.io/pods/templates/environment-variables).

Inferenze in questo step: base comune completa per semplificare il passaggio tra workflow e correzione candidata dell'accesso ComfyUI dal browser.

