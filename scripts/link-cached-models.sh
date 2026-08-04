#!/usr/bin/env bash
# POINT COMFYUI AT RUNPOD'S CACHED MODEL.
#
# The weights are neither in this image nor on a rented volume. RunPod's model
# cache stages a Hugging Face repo onto the host machines themselves: no monthly
# storage charge, no datacenter pin, and no worker billing while it downloads.
# That is what lets this endpoint cost exactly nothing between clips.
#
# It comes with two shapes that have to be reconciled here:
#
#   1. The cache lays the repo out Hugging Face's way, under a snapshot
#      directory named for a commit hash that changes whenever the repo does.
#      So the path is resolved by glob at boot, never hard-coded.
#   2. The repo keeps its files flat at the root, while ComfyUI looks for them
#      in models/diffusion_models, models/text_encoders and models/vae. Symlinks
#      cost nothing and leave the cache untouched for other workers on the host.
#
# If the cache is absent the script says so and exits 0 rather than failing: a
# worker with no models produces a clear "model not found" from ComfyUI, which
# is easier to read than a start-up crash.
set -euo pipefail

REPO="models--Gluttony10--MiniMax-H3-INT8-CONVROT"
CACHE_ROOT="/runpod-volume/huggingface-cache/hub/${REPO}/snapshots"

if [ ! -d "$CACHE_ROOT" ]; then
  echo "link-cached-models: no cache at $CACHE_ROOT — is the endpoint's Model set?"
  exit 0
fi

SNAPSHOT=$(find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [ -z "$SNAPSHOT" ]; then
  echo "link-cached-models: $CACHE_ROOT exists but holds no snapshot yet"
  exit 0
fi
echo "link-cached-models: using $SNAPSHOT"

# source-in-repo  destination-under-/comfyui/models
LINKS="
MiniMax-H3-FL2VA-int8_convrot.safetensors diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors
qwen3-vl-32b-int8_convrot.safetensors text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors
MiniMax-H3-video_vae.safetensors vae/minimax_h3_video_vae.safetensors
MiniMax-H3-audio_vae.safetensors vae/minimax_h3_audio_vae.safetensors
"

echo "$LINKS" | while read -r src dest; do
  [ -z "$src" ] && continue
  mkdir -p "/comfyui/models/$(dirname "$dest")"
  if [ ! -f "$SNAPSHOT/$src" ]; then
    echo "link-cached-models: MISSING $src in the cache"
    continue
  fi
  ln -sfn "$SNAPSHOT/$src" "/comfyui/models/$dest"
  echo "link-cached-models: $dest -> $src"
done

echo "link-cached-models: ready"
