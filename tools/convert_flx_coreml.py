"""Builds Mirada's FLX CoreML models with the coremltools MIL builder.

Both eyes live in one model so a frame costs one prediction call:
  inputs   left_image, right_image       (1, 48, 64, 3) RGB in [0,1], HWC
           left_anchors, right_anchors   (1, 12) x0,y0,...,x5,y5 in crop pixels
           angle                         (1, 2) [vertical, horizontal] degrees
  outputs  left_flow, right_flow         (1, 48, 64, 2) tanh flow, normalized units
           left_light, right_light       (1, 48, 64, 2) softmax light weights

The warp and light correction are NOT in the model: Mirada applies them in
float32 (Swift reference + Metal compositor). Half precision can't hold the
0-64 px sampling coordinates (1/16 px steps flip the in-bounds mask), while the
network itself is fine in fp16. See DECISIONS.md, step 4.

The network follows upstream flx.py exactly: conv -> ReLU -> BatchNorm blocks,
coarse level at half resolution, nearest 2x upsampling, a 2x2 stride-1 average
with TF 'same' padding (pad bottom/right, padding excluded from the mean).

Ships two compiled models into Sources/MiradaKit/Resources/:
  FLXFlow16.mlmodelc   fp16, default, runs on the Neural Engine
  FLXFlow32.mlmodelc   fp32, `--backend cpu`, exact
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

import convert_flx as base

H, W = base.H, base.W
RESOURCES = os.path.join(base.ROOT, "Sources/MiradaKit/Resources")
SHIPPED = {"FLXFlow16": "fp16", "FLXFlow32": "fp32"}


def build(precision):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import types

    weights = {side: base.checkpoint_weights(eye) for side, eye in base.SIDES.items()}

    rows = np.arange(H, dtype=np.float32)[:, None] * np.ones((1, W), np.float32)
    cols = np.ones((H, 1), np.float32) * np.arange(W, dtype=np.float32)[None, :]
    anchor_grid = np.stack([cols if c % 2 == 0 else rows for c in range(12)])[None]  # (1,12,H,W)

    def conv(x, w):
        return mb.conv(x=x, weight=np.transpose(w, (3, 2, 0, 1)), pad_type="same")  # (kh,kw,in,out)->(out,in,kh,kw)

    def cnn_blk(x, p, prefix):
        y = mb.relu(x=conv(x, p[f"{prefix}/cnn/kernel"]))
        return mb.batch_norm(
            x=y,
            mean=p[f"{prefix}/bn_layer/moving_mean"],
            variance=p[f"{prefix}/bn_layer/moving_variance"],
            gamma=p[f"{prefix}/bn_layer/gamma"],
            beta=p[f"{prefix}/bn_layer/beta"],
            epsilon=1e-5,
        )

    def trans_module(x, p, prefix):
        b0 = cnn_blk(x, p, f"{prefix}/cnn_blk_0")
        b1 = cnn_blk(b0, p, f"{prefix}/cnn_blk_1")
        b2 = cnn_blk(mb.concat(values=[b0, b1], axis=1), p, f"{prefix}/cnn_blk_2")
        b3 = cnn_blk(mb.concat(values=[b0, b1, b2], axis=1), p, f"{prefix}/cnn_blk_3")
        return conv(b3, p[f"{prefix}/cnn_4/kernel"])

    def dense(x, p, prefix):
        return mb.relu(x=mb.linear(x=x, weight=p[f"{prefix}/dnn/kernel"].T, bias=p[f"{prefix}/dnn/bias"]))

    def eye(image_hwc, anchors, angle, p):
        img = mb.transpose(x=image_hwc, perm=[0, 3, 1, 2])
        amap = mb.sub(x=anchor_grid, y=mb.reshape(x=anchors, shape=[1, 12, 1, 1]))
        e = dense(dense(dense(angle, p, "encoder/dnn_blk_0"), p, "encoder/dnn_blk_1"), p, "encoder/dnn_blk_2")
        agl = mb.tile(x=mb.reshape(x=e, shape=[1, 16, 1, 1]), reps=[1, 1, H, W])
        inputs = mb.concat(values=[img, amap, agl], axis=1)  # (1,31,H,W)

        down = mb.avg_pool(x=inputs, kernel_sizes=[2, 2], strides=[2, 2], pad_type="valid")
        coarse = mb.tanh(x=trans_module(down, p, "warping_module/coarse_level"))
        coarse = mb.upsample_nearest_neighbor(x=coarse, scale_factor_height=2, scale_factor_width=2)
        coarse = mb.avg_pool(x=coarse, kernel_sizes=[2, 2], strides=[1, 1], pad_type="custom",
                             pad=[0, 1, 0, 1], exclude_padding_from_average=True)
        fine = trans_module(mb.concat(values=[inputs, coarse], axis=1), p, "warping_module/fine_level")
        flow = mb.tanh(x=mb.slice_by_index(x=fine, begin=[0, 0, 0, 0], end=[1, 2, H, W]))
        lcm_in = mb.slice_by_index(x=fine, begin=[0, 2, 0, 0], end=[1, 4, H, W])
        l1 = cnn_blk(cnn_blk(lcm_in, p, "lcm_module/cnn_blk_0"), p, "lcm_module/cnn_blk_1")
        light = mb.softmax(x=conv(l1, p["lcm_module/cnn_2/kernel"]), axis=1)
        return mb.transpose(x=flow, perm=[0, 2, 3, 1]), mb.transpose(x=light, perm=[0, 2, 3, 1])

    specs = [
        mb.TensorSpec(shape=(1, H, W, 3), dtype=types.fp32),
        mb.TensorSpec(shape=(1, 12), dtype=types.fp32),
        mb.TensorSpec(shape=(1, H, W, 3), dtype=types.fp32),
        mb.TensorSpec(shape=(1, 12), dtype=types.fp32),
        mb.TensorSpec(shape=(1, 2), dtype=types.fp32),
    ]

    @mb.program(input_specs=specs, opset_version=ct.target.macOS14)
    def prog(left_image, left_anchors, right_image, right_anchors, angle):
        lf, ll = eye(left_image, left_anchors, angle, weights["left"])
        rf, rl = eye(right_image, right_anchors, angle, weights["right"])
        return (mb.identity(x=lf, name="left_flow"), mb.identity(x=ll, name="left_light"),
                mb.identity(x=rf, name="right_flow"), mb.identity(x=rl, name="right_light"))

    model = ct.convert(
        prog,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32 if precision == "fp32" else ct.precision.FLOAT16,
    )
    model.short_description = "FLX gaze warping flow (Hsu et al. 2019), both eyes. Weights BSD-3, (c) 2019 Chih-Fan Hsu."
    model.version = "1"
    return model


def tf_sampler(img, flow, light):
    """Reference warp + light correction, float32, TF semantics.
    img (H,W,3), flow (H,W,2) after tanh, light (H,W,2) after softmax."""
    gx = np.linspace(-1, 1, W, dtype=np.float32)[None, :]
    gy = np.linspace(-1, 1, H, dtype=np.float32)[:, None]
    x = (flow[..., 0] + gx + 1) * np.float32(0.5 * W)
    y = (flow[..., 1] + gy + 1) * np.float32(0.5 * H)
    inside = (x >= 0) & (x < W - 1) & (y >= 0) & (y < H - 1)
    x0 = np.clip(np.floor(x), 0, W - 2).astype(int)
    y0 = np.clip(np.floor(y), 0, H - 2).astype(int)
    fx = (x - x0)[..., None]
    fy = (y - y0)[..., None]
    out = (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy)
           + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)
    return out * inside[..., None] * light[..., :1] + light[..., 1:]


def check(model):
    """Worst and mean |error| vs the TF goldens, over the whole crop and over the
    region the compositor uses (3 px rows, 4 px columns trimmed)."""
    angles = json.load(open(os.path.join(base.GOLDEN, "angles.json")))["angles"]
    worst_all = worst_in = 0.0
    means = []
    for name in base.CASES:
        manifest = json.load(open(os.path.join(base.GOLDEN, f"{name}.json")))
        feeds = {}
        for side in ("left", "right"):
            feeds[f"{side}_image"] = np.fromfile(os.path.join(base.GOLDEN, f"{name}_{side}_rgb.bin"), "<f4").reshape(1, H, W, 3)
            feeds[f"{side}_anchors"] = np.array(manifest[side]["anchorPoints"], np.float32).reshape(1, 12)
        for k, angle in enumerate(angles):
            feeds["angle"] = np.array([angle], np.float32)
            pred = model.predict(feeds)
            for side in ("left", "right"):
                want = np.fromfile(os.path.join(base.GOLDEN, f"{name}_{side}_a{k}_out.bin"), "<f4").reshape(H, W, 3)
                got = tf_sampler(feeds[f"{side}_image"].reshape(H, W, 3),
                                 np.asarray(pred[f"{side}_flow"], np.float32).reshape(H, W, 2),
                                 np.asarray(pred[f"{side}_light"], np.float32).reshape(H, W, 2))
                err = np.abs(got - want)
                worst_all = max(worst_all, float(err.max()))
                worst_in = max(worst_in, float(err[3:-3, 4:-4].max()))
                means.append(float(err.mean()))
    return {"worst": worst_all, "worstInterior": worst_in, "mean": float(np.mean(means))}


def main():
    import coremltools as ct

    results = {}
    for name, precision in SHIPPED.items():
        model = build(precision)
        with tempfile.TemporaryDirectory() as tmp:
            pkg = os.path.join(tmp, f"{name}.mlpackage")
            model.save(pkg)
            units = ct.ComputeUnit.CPU_AND_NE if precision == "fp16" else ct.ComputeUnit.CPU_ONLY
            results[name] = check(ct.models.MLModel(pkg, compute_units=units))
            dest = os.path.join(RESOURCES, f"{name}.mlmodelc")
            shutil.rmtree(dest, ignore_errors=True)
            subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, RESOURCES], check=True, stdout=subprocess.DEVNULL)
        print(f"{name} ({precision}): {results[name]}")
    json.dump(results, open(os.path.join(base.GOLDEN, "coreml_parity.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
