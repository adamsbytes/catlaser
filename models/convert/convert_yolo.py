#!/usr/bin/env python3
"""Convert YOLOv8n ONNX model to RKNN INT8 for RV1106 NPU.

Expects:
  - Input:  ../yolov8n-coco.onnx (opset 12, no NMS head)
  - Output: ../yolov8n-coco.rknn
  - Calibration images listed in ../calibration/calibration.txt

Mean/std are fused into the model graph so the runtime receives raw
uint8 pixels (0-255) in NHWC order with no CPU-side normalization.
"""

from __future__ import annotations

import sys
from pathlib import Path

from rknn.api import RKNN

MODELS_DIR = Path(__file__).resolve().parent.parent
ONNX_PATH = MODELS_DIR / "yolov8n-coco.onnx"
RKNN_PATH = MODELS_DIR / "yolov8n-coco.rknn"
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

    # YOLO trained on ImageNet-normalized 0-255 RGB input.
    # Fuse mean=[0,0,0] std=[255,255,255] so runtime feeds raw uint8.
    rknn.config(
        mean_values=[[0, 0, 0]],
        std_values=[[255, 255, 255]],
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
