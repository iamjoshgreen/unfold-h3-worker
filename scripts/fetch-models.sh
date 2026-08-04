#!/usr/bin/env bash
# FETCH MINIMAX H3 ONTO THE WORKER'S OWN DISK, AT STARTUP.
#
# This is worker-comfyui's documented answer for running without a persistent
# volume: a startup script that pulls the weights into ComfyUI's model folders.
# It is used here because every other route is closed:
#
#   - Baking 54GB into the image took 11 minutes just to package and blew
#     RunPod's 30-minute build ceiling. Their 80GB size cap and 30-minute clock
#     contradict each other at this scale.
#   - A network volume charges rent every month AND pins the endpoint to one
#     datacenter; ours had zero cards free at any size, so nothing could run.
#   - RunPod's model cache would be ideal — host-side, unbilled — but the
#     console's Model field silently refuses to save, twice, as a URL and as a
#     repo id.
#
# The cost of this route is honest and worth stating: the download happens on
# BILLED worker time, unlike the model cache. It is per worker, not per job —
# FlashBoot pauses idle workers rather than destroying them, so a warm worker
# keeps its models and every later clip skips this entirely.
#
# Idempotent: each file lands under a .part name and is size-checked before the
# rename, so a worker killed mid-download never leaves a truncated file that
# ComfyUI would half-load and fail on in a way that looks like a model bug.
set -euo pipefail

ROOT="/comfyui/models"
REPO="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"

# path-under-models  expected-bytes
FILES="
diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors 20970379616
text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors 27141342152
vae/minimax_h3_video_vae_fp16.safetensors 5207808496
vae/minimax_h3_audio_vae_fp32.safetensors 605254808
"

echo "$FILES" | while read -r rel expected; do
  [ -z "$rel" ] && continue
  dest="$ROOT/$rel"
  mkdir -p "$(dirname "$dest")"

  if [ -f "$dest" ]; then
    actual=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    # Within 1% is the same file; Hugging Face occasionally reports a slightly
    # different byte count than it serves.
    if [ "$actual" -gt $((expected - expected / 100)) ]; then
      echo "fetch-models: have $rel"
      continue
    fi
    echo "fetch-models: $rel is short ($actual vs $expected) — refetching"
    rm -f "$dest"
  fi

  echo "fetch-models: downloading $rel ($((expected / 1000000000))GB)…"
  wget -q --show-progress --progress=dot:giga -O "$dest.part" "$REPO/$rel"
  actual=$(stat -c %s "$dest.part")
  if [ "$actual" -lt $((expected - expected / 100)) ]; then
    echo "fetch-models: $rel came back short ($actual vs $expected) — not installing"
    rm -f "$dest.part"
    exit 1
  fi
  mv "$dest.part" "$dest"
  echo "fetch-models: installed $rel"
done

echo "fetch-models: ready"
ls -la "$ROOT/diffusion_models" "$ROOT/text_encoders" "$ROOT/vae" 2>/dev/null || true
