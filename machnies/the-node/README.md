# the-node

GPU-Host (Linux, NVIDIA, Tailscale) mit llama.cpp (Chat, Port 8000), text-embeddings-inference (Port 8001)
und Grafana Alloy (Metriken/Logs). Die Dienste sind nur über die Tailscale-IP erreichbar; der
agentgateway im Cluster spricht sie von dort an (siehe `clusters/homelab/namespaces/agentgateway-system`).

`the-node` ist der logische Name in Cluster und Repo; der Tailnet-Hostname ist `gpu-node`
(`gpu-node.tailea8881.ts.net`). Dieser Name steht in `clusters/homelab/infrastructure/gateway/proxy-node.yaml`
und muss mit dem Hostnamen im Tailnet übereinstimmen (`setup.sh` warnt bei Abweichung).

## Voraussetzungen (manuell, einmalig)

- Docker mit Compose-Plugin und `nvidia-container-toolkit` (Runtime `nvidia`), NVIDIA-Treiber ≥ 580 (CUDA 13)
- Tailscale installiert und eingeloggt (`tailscale up`)
- Repo nach `/srv/homelab` geklont: `git clone git@github.com:BotondGal/homelab.git /srv/homelab`
- HuggingFace-Token (`hf_...`) und akzeptierte Lizenz von [google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m)
  (gated; bei Fine-grained-Token „Read access to gated repos“ aktivieren)
- Optional: bereits genutzter llama-API-Key (gleicher Wert wie im SOPS-Secret `the-node.enc.yaml`)

## Setup

```sh
cd /srv/homelab/machnies/the-node
sudo ./setup.sh          # oder: make setup
```

Das Script ist idempotent und erledigt:

1. Prüft Voraussetzungen (Docker, NVIDIA-Runtime, Treiber, Tailscale-IP)
2. Legt `secrets/llama_api_key.txt` an (Key abfragen oder generieren; ein neuer Key muss ins Cluster-Secret)
3. Lädt die Modelle nach `/srv/llamacpp/models/unsloth` und `/srv/tei/models/embeddinggemma-300m`
   (Token wird abgefragt oder aus `HF_TOKEN` gelesen und nicht gespeichert; Downloads sind fortsetzbar)
4. Aktiviert das persistente systemd-Journal (für Alloy) und erlaubt `git pull` als root
5. Zieht die Docker-Images vor (das Unit hat nur 90 s Start-Timeout)
6. Verlinkt/aktiviert/startet `llm-compose.service` und prüft per Chat- und Embedding-Request

`--no-start` installiert nur, ohne zu starten. Beim Boot macht das Unit `git pull --ff-only` und startet
dann `start.sh` (schreibt `.env` mit `TS_IP`, `docker compose up -d`).
