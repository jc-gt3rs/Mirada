"""FLX weight conversion and golden reference outputs for Mirada.

The reference is the ORIGINAL upstream training graph (L.meta / R.meta from
chihfanhsu/gaze_correction), restored from its checkpoints and run with
phase_train=False. Nothing here re-implements the network for the reference.

Commands (run from the repo root with tools/.venv/bin/python -I):
  golden   Run TF on Tests/Fixtures/golden/<name>_*_rgb.bin inputs and write
           <name>_<side>_a<k>_out.bin plus angles.json.
  coreml   Build Sources/MiradaKit/Resources/FLX.mlpackage (both eyes, warp
           and light correction included) and check it against the goldens.
  weights  Export the checkpoint weights as safetensors (for the MLX benchmark).

Requires tools/fetch_upstream.sh to have been run.
"""
import json
import os
import struct
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CKPT = os.path.join(ROOT, "tools/upstream/weights/weights/warping_model/flx/12")
GOLDEN = os.path.join(ROOT, "Tests/Fixtures/golden")
H, W = 48, 64

# [vertical, horizontal] degrees. Covers zero, small, typical webcam and large.
ANGLES = [(0.0, 0.0), (-8.0, 2.5), (15.0, -20.0), (-25.0, 30.0)]
CASES = ["glasses", "plain"]
# Which checkpoint corrects which eye: "L" is the subject's left eye.
SIDES = {"left": "L", "right": "R"}


def anchor_map(points):
    rows = np.arange(H)[:, None]
    cols = np.arange(W)[None, :]
    chans = []
    for x, y in points:
        chans.append(np.broadcast_to(cols - x, (H, W)))
        chans.append(np.broadcast_to(rows - y, (H, W)))
    return np.stack(chans, axis=2).astype(np.float32)


def load_case(name, side):
    manifest = json.load(open(os.path.join(GOLDEN, f"{name}.json")))
    rgb = np.fromfile(os.path.join(GOLDEN, f"{name}_{side}_rgb.bin"), dtype="<f4").reshape(H, W, 3)
    return rgb, anchor_map(manifest[side]["anchorPoints"])


def run_tf_reference():
    import tensorflow as tf

    tf.compat.v1.disable_eager_execution()
    out = {}
    for side, eye in SIDES.items():
        g = tf.Graph()
        with g.as_default():
            saver = tf.compat.v1.train.import_meta_graph(os.path.join(CKPT, eye, f"{eye}.meta"), clear_devices=True)
            with tf.compat.v1.Session(graph=g) as sess:
                saver.restore(sess, os.path.join(CKPT, eye, eye))
                pred = g.get_tensor_by_name("tower_0/warping_model/apply_lcm/Add:0")
                for name in CASES:
                    rgb, anchors = load_case(name, side)
                    for k, angle in enumerate(ANGLES):
                        # The training graph splits the batch across two towers; feed two copies.
                        feed = {
                            "inputs/input_img:0": np.stack([rgb, rgb]),
                            "inputs/input_fp:0": np.stack([anchors, anchors]),
                            "inputs/input_ang:0": np.array([angle, angle], dtype=np.float32),
                            "model_control/phase_train:0": False,
                        }
                        result = sess.run(pred, feed_dict=feed)
                        out[(name, side, k)] = result[0].astype(np.float32)
    return out


def golden():
    out = run_tf_reference()
    for (name, side, k), img in out.items():
        img.astype("<f4").tofile(os.path.join(GOLDEN, f"{name}_{side}_a{k}_out.bin"))
    json.dump({"angles": ANGLES, "cases": CASES}, open(os.path.join(GOLDEN, "angles.json"), "w"), indent=1)
    for (name, side, k), img in sorted(out.items()):
        rgb, _ = load_case(name, side)
        print(f"{name:8s} {side:5s} angle {ANGLES[k]}: mean |out - in| = {np.abs(img - rgb).mean():.4f}, range [{img.min():.3f}, {img.max():.3f}]")


def checkpoint_weights(eye):
    import tensorflow as tf

    reader = tf.train.load_checkpoint(os.path.join(CKPT, eye, eye))
    names = reader.get_variable_to_shape_map().keys()
    keep = [n for n in names if n.startswith("warping_model/") and "Adam" not in n]
    return {n[len("warping_model/"):]: reader.get_tensor(n).astype(np.float32) for n in keep}


def write_safetensors(tensors, path):
    header, offset, blobs = {}, 0, []
    for name in sorted(tensors):
        data = np.ascontiguousarray(tensors[name], dtype="<f4").tobytes()
        header[name] = {"dtype": "F32", "shape": list(tensors[name].shape), "data_offsets": [offset, offset + len(data)]}
        offset += len(data)
        blobs.append(data)
    raw = json.dumps(header).encode()
    raw += b" " * ((8 - len(raw) % 8) % 8)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(raw)))
        f.write(raw)
        for b in blobs:
            f.write(b)


def weights(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for side, eye in SIDES.items():
        path = os.path.join(out_dir, f"flx_{eye}.safetensors")
        write_safetensors(checkpoint_weights(eye), path)
        print("wrote", path)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "golden":
        golden()
    elif cmd == "weights":
        weights(sys.argv[2])
    elif cmd == "coreml":
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import convert_flx_coreml

        convert_flx_coreml.main()
    else:
        print(__doc__)
        sys.exit(64)
