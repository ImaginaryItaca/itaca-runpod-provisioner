"""ITACA - controlla che ComfyUI abbia registrato tutti i nodi usati dai workflow (Task 3, 2026-10-27).

Uso: python verifica_nodi.py <cartella dei workflow>
Legge i nodi di ogni workflow, compresi quelli dentro i subgraph, e li confronta con /object_info.
"""
import json
import pathlib
import re
import sys
import urllib.request

# Nodi che esistono solo nell'interfaccia e non compaiono in /object_info.
SOLO_INTERFACCIA = {
    "Note",
    "MarkdownNote",
    "Reroute",
    "PrimitiveNode",
    "Fast Groups Bypasser (rgthree)",
    "Fast Groups Muter (rgthree)",
}
# Le istanze dei subgraph hanno come tipo l'id del subgraph.
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def tipi_usati(percorso):
    grafo = json.loads(percorso.read_text(encoding="utf-8"))
    nodi = list(grafo.get("nodes", []))
    for subgraph in grafo.get("definitions", {}).get("subgraphs", []):
        nodi += subgraph.get("nodes", [])
    return {
        n["type"]
        for n in nodi
        if not UUID.match(n["type"]) and n["type"] not in SOLO_INTERFACCIA
    }


def main():
    cartella = pathlib.Path(sys.argv[1])
    with urllib.request.urlopen("http://127.0.0.1:8188/object_info", timeout=120) as risposta:
        registrati = set(json.load(risposta))
    errori = False
    for workflow in sorted(cartella.glob("*.json")):
        mancanti = sorted(tipi_usati(workflow) - registrati)
        if mancanti:
            errori = True
            print(f"[ITACA] MANCANO in {workflow.name}: {', '.join(mancanti)}")
        else:
            print(f"[ITACA] OK {workflow.name}: tutti i nodi sono registrati")
    sys.exit(1 if errori else 0)


if __name__ == "__main__":
    main()
