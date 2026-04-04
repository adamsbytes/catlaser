#!/usr/bin/env python3
"""Convert MobileNetV2 cat re-ID ONNX model to RKNN INT8 for RV1106 NPU.

Expects:
  - Input:  ../cat_reid_mobilenet.onnx (opset 12, no L2 norm layer)
  - Output: ../cat_reid_mobilenet.rknn
  - Calibration images listed in ../calibration/calibration.txt

Uses ImageNet normalization fused into the graph. L2 normalization of
the 128-dim embedding vector is performed in Rust post-processing, not
on the NPU (ReduceL2 is unsupported on RV1106).
"""

from __future__ import annotations

import sys
from pathlib import Path

from rknn.api import RKNN

MODELS_DIR = Path(__file__).resolve().parent.parent
ONNX_PATH = MODELS_DIR / "cat_reid_mobilenet.onnx"
RKNN_PATH = MODELS_DIR / "cat_reid_mobilenet.rknn"
CALIBRATION_LIST = MODELS_DIR / "calibration" / "calibration.txt"


def convert() -> int:
    """Run the full ONNX-to-RKNN conversion pipeline."""
    if not ONNX_PATH.exists():
        print(f"ONNX model not found: {ONNX_PATH}", file=sys.stderr)
        return 1

    if not CALIBRATION_LIST.exists():
        print(f"Calibration list not found: {CALIBRATION_LIST}", file=sys.stderr)
        return 1

    rknn = RKNN(verbose=True)

    # ImageNet normalization fused into graph.
    # Runtime feeds raw uint8 RGB pixels, no CPU-side preprocessing.
    rknn.config(
        mean_values=[[123.675, 116.28, 103.53]],
        std_values=[[58.395, 57.12, 57.375]],
        target_platform="rv1106",
        quantized_algorithm="mmse",
    )

    ret = rknn.load_onnx(model=str(ONNX_PATH))
    if ret != 0:
        print("Failed to load ONNX model", file=sys.stderr)
        rknn.release()
        return 1

    ret = rknn.build(do_quantization=True, dataset=str(CALIBRATION_LIST))
    if ret != 0:
        print("Failed to build RKNN model", file=sys.stderr)
        rknn.release()
        return 1

    ret = rknn.export_rknn(str(RKNN_PATH))
    if ret != 0:
        print("Failed to export RKNN model", file=sys.stderr)
        rknn.release()
        return 1

    rknn.release()
    print(f"Conversion complete: {RKNN_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(convert())
