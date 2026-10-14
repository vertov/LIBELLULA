"""Cross-check libstmd.metrics against a line-by-line transcription of the
reference evaluator (utils/eval.py), on random and model predictions."""
import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from scipy import ndimage
from libstmd import data, model, metrics


def reference(seqs, preds, pd_detT=50, correct_thresh=1e-4, thresh=0.9):
    obj_num = correct_num = false_num = frame_num = 0
    gts, prs = [], []
    for s, pr in zip(seqs, preds):
        ts = s.t_ms.astype(np.float64)
        preds_all = pr.astype(np.float64)
        label = s.label.astype(np.float64)
        idx = s.ident.astype(np.float64)
        locs = np.stack([s.x, s.y, s.t_ms], 1)
        frame_num += int((ts.max() - ts.min()) / pd_detT)
        for i in range(int((ts.max() - ts.min()) / pd_detT + 1)):
            t_range = (ts > i * pd_detT) * (ts < (i + 1) * pd_detT)
            idx_frame, preds_frame, label_frame, locs_frame = idx[t_range], preds_all[t_range].copy(), label[t_range], locs[t_range]
            ori = preds_frame.copy()
            false_mask = np.zeros((260, 346), dtype=np.uint8)
            preds_frame[ori >= thresh] = 1
            preds_frame[ori < thresh] = 0
            for idx_i in set(idx_frame.tolist()):
                if idx_i != 0:
                    obj_num += 1
                    p_i = preds_frame[idx_frame == idx_i]
                    l_i = label_frame[idx_frame == idx_i]
                    if (p_i == l_i).sum() / l_i.sum() >= correct_thresh:
                        correct_num += 1
            fe = locs_frame[(label_frame == 0) * (preds_frame == 1)]
            for ii in range(fe.shape[0]):
                false_mask[int(fe[ii, 1]), int(fe[ii, 0])] += 1
            _, n = ndimage.label(false_mask, structure=np.ones((3, 3)))
            false_num += n
        gts.append(label == 1); prs.append(preds_all >= thresh)
    g = np.concatenate(gts); p = np.concatenate(prs)
    return {"IoU": (g & p).sum() / (g | p).sum(), "ACC": (g & p).sum() / g.sum(),
            "Pd": correct_num / obj_num, "Fa": false_num / (frame_num * 346 * 260)}


if __name__ == "__main__":
    seqs = data.load_dir(sys.argv[1])[:int(sys.argv[2])]
    cfg = model.Params(**json.load(open(__import__("os").path.join(__import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))), "configs", "all_stages.json"))))
    rng = np.random.default_rng(0)
    for name, preds in (("random10%", [rng.random(len(s.x)) < 0.1 for s in seqs]),
                        ("model", [model.run(s, cfg)["pred"] for s in seqs])):
        m = metrics.EvUAVMetrics()
        for s, pr in zip(seqs, preds):
            m.update(s.t_ms, s.x, s.y, s.label, s.ident, pr)
        a = m.result(); b = reference(seqs, preds)
        print(name, {k: (round(float(a[k]), 6), round(float(b[k]), 6)) for k in ("IoU", "ACC", "Pd", "Fa")},
              "MATCH" if all(abs(a[k] - b[k]) < 1e-12 for k in ("IoU", "ACC", "Pd", "Fa")) else "DIFF")
