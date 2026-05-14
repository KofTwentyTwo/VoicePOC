#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
DEST_OWW="Resources/models/openWakeWord"
DEST_SILERO="Resources/models/silero"

OWW_BASE="https://github.com/dscripka/openWakeWord/raw/main/openwakeword/resources/models"
SILERO_URL="https://github.com/snakers4/silero-vad/raw/v6.2.1/files/silero_vad.onnx"

echo "==> openWakeWord (hey_jarvis_v0.1, mel, embedding)"
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
