#!/usr/bin/env bash
# Provisions the-node: checks prerequisites, downloads the HuggingFace models,
# creates the llama API key, pre-pulls the images and installs/starts
# llm-compose.service. Safe to re-run (existing files and keys are kept).
#
# Usage: sudo ./setup.sh [--no-start]
#   HF_TOKEN      HuggingFace token (prompted if models are missing and unset)
#   LLAMA_API_KEY existing llama API key (prompted if unset; generated if left empty)
set -euo pipefail

NODE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$NODE_DIR" rev-parse --show-toplevel)

# Fixed by docker-compose.yml (volumes) and llm-compose.service (paths)
EXPECTED_REPO_ROOT=/srv/homelab
LLAMA_DIR=/srv/llamacpp/models/unsloth
TEI_DIR=/srv/tei/models/embeddinggemma-300m
SECRET_FILE=$NODE_DIR/secrets/llama_api_key.txt
UNIT_FILE=$NODE_DIR/llm-compose.service

# Must match the model/mmproj paths in docker-compose.yml
LLAMA_REPO=unsloth/gemma-4-12b-it-GGUF
LLAMA_FILES=(gemma-4-12b-it-Q4_K_M.gguf mmproj-BF16.gguf)
# Gated: the license has to be accepted once on the HuggingFace model page
TEI_REPO=google/embeddinggemma-300m
TEI_REQUIRED=(config.json tokenizer.json modules.json model.safetensors)
TEI_SKIP='^(\.gitattributes|README\.md|notebook\.ipynb)$'

# Tailnet name the cluster's egress Service targets (infrastructure/gateway/proxy-node.yaml)
EXPECTED_TS_FQDN=gpu-node.tailea8881.ts.net

HEALTH_TIMEOUT=600

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# curl against huggingface.co; the token is piped in so it never shows up in `ps`
hf_curl() { printf 'Authorization: Bearer %s\n' "$HF_TOKEN" | curl -H @- "$@"; }

preflight() {
    [[ $(uname -s) == Linux ]] || die "this script provisions the Linux host (the-node), not $(uname -s)"
    [[ $REPO_ROOT == "$EXPECTED_REPO_ROOT" ]] ||
        die "repo is at $REPO_ROOT but llm-compose.service expects $EXPECTED_REPO_ROOT (git clone git@github.com:BotondGal/homelab.git $EXPECTED_REPO_ROOT)"

    local cmd
    for cmd in git curl python3 docker tailscale systemctl nvidia-smi; do
        command -v "$cmd" >/dev/null || die "missing command: $cmd"
    done

    docker info >/dev/null 2>&1 || die "docker daemon not reachable"
    docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
    docker info --format '{{json .Runtimes}}' | grep -q nvidia ||
        die "docker has no 'nvidia' runtime: install nvidia-container-toolkit, then 'nvidia-ctk runtime configure --runtime=docker && systemctl restart docker'"

    local driver
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1) ||
        die "nvidia-smi failed: NVIDIA driver not working"
    log "GPU driver $driver"
    # llama.cpp image is built against CUDA 13
    (( ${driver%%.*} >= 580 )) || warn "driver $driver is older than 580, which the CUDA 13 llama.cpp image needs"

    TS_IP=$(tailscale ip -4 2>/dev/null | head -n1) || true
    [[ -n ${TS_IP:-} ]] || die "tailscale is not connected (run 'tailscale up')"
    log "tailscale IP $TS_IP"

    local fqdn
    fqdn=$(tailscale status --json | python3 -c 'import json, sys
print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))') || true
    [[ $fqdn == "$EXPECTED_TS_FQDN" ]] ||
        warn "tailnet name is '${fqdn:-unknown}', the cluster expects $EXPECTED_TS_FQDN (clusters/homelab/infrastructure/gateway/proxy-node.yaml)"
}

setup_dirs() {
    log "creating model directories"
    mkdir -p "$LLAMA_DIR" "$TEI_DIR"
}

# The file is bind-mounted into llama-server and alloy; the 0700 directory keeps
# other local users out, the 0644 file stays readable for non-root container users.
setup_api_key() {
    if [[ -s $SECRET_FILE ]]; then
        log "API key exists: $SECRET_FILE"
        return
    fi
    local key=${LLAMA_API_KEY:-} generated=0
    if [[ -z $key && -t 0 ]]; then
        read -rsp "Existing llama API key (empty = generate a new one): " key
        echo
    fi
    if [[ -z $key ]]; then
        key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        generated=1
    fi
    install -d -m 0700 "$(dirname "$SECRET_FILE")"
    printf '%s\n' "$key" > "$SECRET_FILE"
    chmod 0644 "$SECRET_FILE"
    log "API key written to $SECRET_FILE"
    if (( generated )); then
        warn "key was generated: put 'Bearer <key>' into the cluster secret clusters/homelab/namespaces/agentgateway-system/the-node.enc.yaml (Authorization)"
    fi
}

models_present() {
    local f
    for f in "${LLAMA_FILES[@]}"; do [[ -s $LLAMA_DIR/$f ]] || return 1; done
    for f in "${TEI_REQUIRED[@]}"; do [[ -s $TEI_DIR/$f ]] || return 1; done
}

ensure_hf_token() {
    if [[ -z ${HF_TOKEN:-} ]]; then
        [[ -t 0 ]] || die "models are missing and HF_TOKEN is not set (no terminal to prompt on)"
        read -rsp "HuggingFace token (hf_...): " HF_TOKEN
        echo
    fi
    local code
    code=$(hf_curl -s -o /dev/null -w '%{http_code}' https://huggingface.co/api/whoami-v2) || true
    [[ $code == 200 ]] || die "HuggingFace rejected the token (HTTP $code)"

    code=$(hf_curl -s -o /dev/null -w '%{http_code}' "https://huggingface.co/$TEI_REPO/resolve/main/config.json") || true
    case $code in
        200|302) ;;
        401|403) die "no access to $TEI_REPO: accept the license at https://huggingface.co/$TEI_REPO and, for a fine-grained token, enable read access to gated repos" ;;
        *) die "unexpected HTTP $code while checking access to $TEI_REPO" ;;
    esac
}

# hf_download <repo> <file> <dest>: resumable, atomic (.part -> final)
hf_download() {
    local repo=$1 file=$2 dest=$3
    if [[ -s $dest ]]; then
        log "have $dest"
        return
    fi
    log "downloading $repo/$file"
    mkdir -p "$(dirname "$dest")"
    hf_curl -fL --retry 5 --retry-delay 3 -C - --progress-bar \
        -o "$dest.part" "https://huggingface.co/$repo/resolve/main/$file"
    mv "$dest.part" "$dest"
}

download_models() {
    if models_present; then
        log "models already present"
        return
    fi
    ensure_hf_token

    local f
    for f in "${LLAMA_FILES[@]}"; do
        hf_download "$LLAMA_REPO" "$f" "$LLAMA_DIR/$f"
    done

    local files
    files=$(hf_curl -fsSL "https://huggingface.co/api/models/$TEI_REPO" |
        python3 -c 'import json, sys
for s in json.load(sys.stdin)["siblings"]:
    print(s["rfilename"])') || die "could not list files of $TEI_REPO"
    while IFS= read -r f; do
        [[ $f =~ $TEI_SKIP ]] && continue
        hf_download "$TEI_REPO" "$f" "$TEI_DIR/$f"
    done <<< "$files"
    unset HF_TOKEN
}

# alloy bind-mounts /var/log/journal; without a persistent journal it reads nothing
setup_journal() {
    if [[ -d /var/log/journal ]]; then
        return
    fi
    log "enabling persistent systemd journal"
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
}

# The unit runs `git pull` as root; that fails silently (ExecStartPre=-) on a repo owned by someone else
check_git_pull() {
    if [[ $(stat -c %u "$REPO_ROOT") != 0 ]] &&
        ! git config --system --get-all safe.directory | grep -qxF "$REPO_ROOT"; then
        log "marking $REPO_ROOT as safe.directory for root"
        git config --system --add safe.directory "$REPO_ROOT"
    fi
    if ! GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
        git -C "$REPO_ROOT" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
        warn "root cannot reach 'origin' non-interactively: the pull in llm-compose.service will be skipped (needs a root SSH key / deploy key, or an https remote)"
    fi
}

# The unit has a 90s start timeout, too short for a first image pull
pull_images() {
    log "pulling images"
    (cd "$NODE_DIR" && TS_IP=$TS_IP docker compose pull)
}

install_service() {
    log "installing llm-compose.service"
    systemctl enable "$UNIT_FILE"   # symlinks the unit from the repo, so a git pull also updates it
    systemctl daemon-reload
    if (( START )); then
        log "starting llm-compose.service"
        systemctl restart llm-compose.service
    fi
}

wait_healthy() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT)) c state
    for c in llama-server text-embeddings; do
        log "waiting for $c to become healthy"
        while :; do
            state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
            [[ $state == healthy ]] && break
            if (( SECONDS >= deadline )); then
                docker logs --tail 30 "$c" >&2 || true
                die "$c is '$state' after ${HEALTH_TIMEOUT}s"
            fi
            sleep 5
        done
    done
}

# End-to-end: one real chat and one real embedding request through the Tailscale IP
smoke_test() {
    local key
    key=$(<"$SECRET_FILE")
    log "smoke test: chat completion"
    printf 'Authorization: Bearer %s\n' "$key" | curl -fsS -H @- -H 'Content-Type: application/json' \
        -d '{"model":"unsloth/gemma-4-12B-it-GGUF","messages":[{"role":"user","content":"Say hi"}],"max_tokens":8}' \
        "http://$TS_IP:8000/v1/chat/completions" >/dev/null || die "chat completion failed"
    log "smoke test: embeddings"
    curl -fsS -H 'Content-Type: application/json' \
        -d '{"model":"google/embeddinggemma-300m","input":"hello"}' \
        "http://$TS_IP:8001/v1/embeddings" >/dev/null || die "embedding request failed"
    log "the-node is up: llama http://$TS_IP:8000, embeddings http://$TS_IP:8001"
}

main() {
    START=1
    case ${1:-} in
        --no-start) START=0 ;;
        -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        "") ;;
        *) die "unknown argument: $1" ;;
    esac

    if (( EUID != 0 )); then
        exec sudo -E "${BASH_SOURCE[0]}" "$@"
    fi

    preflight
    setup_dirs
    setup_api_key
    download_models
    setup_journal
    check_git_pull
    pull_images
    install_service
    if (( START )); then
        wait_healthy
        smoke_test
    else
        log "done; start with: systemctl start llm-compose.service"
    fi
}

# Allow sourcing for tests without running anything
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
