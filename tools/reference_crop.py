"""Reference eye crop + anchor map, using the training notebook's math
(chihfanhsu/gaze_correction generate_training_inputs_from_raw_dataset.ipynb).

Prints JSON that Tests/MiradaKitTests/EyeCropTests.swift pins against.
Run with the system python that has OpenCV: python3 -I tools/reference_crop.py
"""
import json
import cv2
import numpy as np

NEW_SIZE = (48, 64)  # (h, w)


def synthetic_rgb(w, h):
    x = np.arange(w)[None, :]
    y = np.arange(h)[:, None]
    r = (x * 7 + y * 3) % 256
    g = (x * 2 + y * 11) % 256
    b = (x * x + y) % 256
    return np.stack([r + 0 * y, g + 0 * x, b], axis=2).astype(np.uint8)


def crop(frame, points):
    # points: 6 (x, y) in training order; corners are points 0 and 3.
    rc, lc = points[0], points[3]
    eye_cx = (rc[0] + lc[0]) * 0.5
    eye_cy = (rc[1] + lc[1]) * 0.5
    eye_len = abs(rc[0] - lc[0])
    bx_d5w = eye_len * 3 / 4
    bx_h = 1.5 * bx_d5w
    sft_up = bx_h * 7 / 12
    sft_low = bx_h * 5 / 12
    top, bottom = int(eye_cy - sft_up + 0.5), int(eye_cy + sft_low + 0.5)
    left, right = int(eye_cx - bx_d5w + 0.5), int(eye_cx + bx_d5w + 0.5)
    img_eye = frame[top:bottom, left:right]
    ori_size = [img_eye.shape[0], img_eye.shape[1]]
    lt = [int(eye_cy - sft_up), int(eye_cx - bx_d5w)]  # (y, x)
    resized = cv2.resize(img_eye, (NEW_SIZE[1], NEW_SIZE[0]))
    anchors = []
    for d in points:
        anchors.append([
            int((d[0] - lt[1]) * NEW_SIZE[1] / ori_size[1] + 0.5),
            int((d[1] - lt[0]) * NEW_SIZE[0] / ori_size[0] + 0.5),
        ])
    return {
        "top": top, "left": left, "height": ori_size[0], "width": ori_size[1],
        "ltY": lt[0], "ltX": lt[1],
        "anchorPoints": anchors,
        "samples": {f"{r},{c}": resized[r, c].tolist() for r, c in [(0, 0), (10, 20), (24, 32), (47, 63), (5, 60), (40, 3)]},
    }


frame = synthetic_rgb(200, 150)
cases = {
    "rightEyeOfSubject": [(62.0, 80.0), (70.0, 74.6), (81.3, 73.0), (90.0, 78.0), (81.0, 82.2), (70.4, 82.9)],
    "leftEyeOfSubject": [(151.7, 77.2), (143.0, 72.4), (131.0, 72.0), (122.6, 77.8), (131.5, 81.0), (143.2, 81.4)],
}
print(json.dumps({k: crop(frame, v) for k, v in cases.items()}, indent=1))
