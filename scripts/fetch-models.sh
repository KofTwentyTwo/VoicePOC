#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
DEST_OWW="Resources/models/openWakeWord"
DEST_SILERO="Resources/models/silero"

# openWakeWord moved its model distribution from in-repo paths to release assets.
# v0.5.1 is the current canonical release with all three ONNX files we need.
OWW_BASE="https://github.com/dscripka/openWakeWord/releases/download/v0.5.1"

# Silero v6.2.1 keeps the ONNX at src/silero_vad/data/silero_vad.onnx (2.3 MB).
SILERO_URL="https://github.com/snakers4/silero-vad/raw/v6.2.1/src/silero_vad/data/silero_vad.onnx"

echo "==> openWakeWord (hey_jarvis_v0.1, mel, embedding) — from v0.5.1 release"
curl -fL --create-dirs -o "$DEST_OWW/hey_jarvis_v0.1.onnx"       "$OWW_BASE/hey_jarvis_v0.1.onnx"
curl -fL --create-dirs -o "$DEST_OWW/melspectrogram.onnx"        "$OWW_BASE/melspectrogram.onnx"
curl -fL --create-dirs -o "$DEST_OWW/embedding_model.onnx"       "$OWW_BASE/embedding_model.onnx"

echo "==> Silero VAD v6.2.1"
curl -fL --create-dirs -o "$DEST_SILERO/silero_vad_v6_2_1.onnx"  "$SILERO_URL"

echo
echo "Downloaded:"
ls -lh "$DEST_OWW"/*.onnx "$DEST_SILERO"/*.onnx
echo
echo "OK. ~7 MB total."
