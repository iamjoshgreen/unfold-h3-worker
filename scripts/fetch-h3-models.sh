#!/usr/bin/env bash
# PUT MINIMAX H3 ON THE NETWORK VOLUME, ONCE.
#
# The bf16 weights are 123.6GB — far past RunPod's 80GB image cap — so they live
# on the network volume instead of inside the image. Nothing else mounts that
# volume: a pod is the usual way to load one, and this setup deliberately has no
# pod (a pod bills by the hour until somebody remembers to stop it). So the
# first serverless worker that boots fills the drive, and every worker after it
# finds the files already there and skips straight to serving.
#
# Idempotent by design: each file is downloaded to a .part name and only moved
# into place once complete, so a worker killed mid-download leaves nothing that
# looks finished. Size is verified against the expected byte count before the
# rename — a truncated 60GB file that ComfyUI half-loads is a far worse failure
# than an honest re-download.
set -euo pipefail

VOLUME_ROOT="${COMFY_MODEL_ROOT:-/runpod-volume/models}"
REPO="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"

# path-under-models  expected-bytes
FILES="
diffusion_models/minimax_h3_fl2va_bf16.safetensors 66280487368
text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors 51506295256
vae/minimax_h3_video_vae_fp16.safetensors 5207808496
vae/minimax_h3_audio_vae_fp32.safetensors 605254808
"

if [ ! -d "$(dirname "$VOLUME_ROOT")" ]; then
  echo "fetch-h3-models: no network volume mounted at $(dirname "$VOLUME_ROOT") — skipping"
  exit 0
fi

echo "$FILES" | while read -r rel expected; do
  [ -z "$rel" ] && continue
  dest="$VOLUME_ROOT/$rel"
  mkdir -p "$(dirname "$dest")"

  if [ -f "$dest" ]; then
    actual=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    # Within 1% of expected is the same file; Hugging Face occasionally reports
    # a slightly different byte count than it serves.
    if [ "$actual" -gt $((expected - expected / 100)) ]; then
      echo "fetch-h3-models: have $rel ($((actual / 1000000000))GB)"
      continue
    fi
    echo "fetch-h3-models: $rel is short ($actual vs $expected) — refetching"
    rm -f "$dest"
  fi

  echo "fetch-h3-models: downloading $rel ($((expected / 1000000000))GB)…"
  wget -q --show-progress --progress=dot:giga -O "$dest.part" "$REPO/$rel"
  actual=$(stat -c %s "$dest.part")
  if [ "$actual" -lt $((expected - expected / 100)) ]; then
    echo "fetch-h3-models: $rel came back short ($actual vs $expected) — not installing"
    rm -f "$dest.part"
    exit 1
  fi
  mv "$dest.part" "$dest"
  echo "fetch-h3-models: installed $rel"
done

echo "fetch-h3-models: volume ready"
