"""Unit tests for the model-free parts of the pipeline (run: pytest catalogue/tests)."""
from pathlib import Path

import numpy as np

from footage_catalogue import audio, edl, probe, shots, visual


def test_timecode_roundtrip():
    for fps in (24.0, 25.0, 29.97, 59.94):
        for fr in (0, 1, 24, 25, 1499, 90000, 215999):
            assert probe.tc_to_frames(probe.frames_to_tc(fr, fps), fps) == fr
    assert probe.frames_to_tc(90000 + 26, 25.0) == "01:00:01:01"


def test_edl_parse_and_boundaries(tmp_path: Path):
    text = """TITLE: scene cuts
FCM: NON-DROP FRAME

001  AX       V     C        01:00:00:00 01:00:04:00 01:00:00:00 01:00:04:00
002  AX       V     C        01:00:04:00 01:00:10:12 01:00:04:00 01:00:10:12
003  AX       V     D    025 01:00:10:12 01:00:20:00 01:00:10:12 01:00:20:00
"""
    p = tmp_path / "x.edl"
    p.write_text(text)
    events, meta = edl.parse_edl(p)
    assert len(events) == 3 and events[2].transition == "D" and events[2].duration == 25
    spans = edl.edl_to_boundaries(p, 25.0, "01:00:00:00", 600)
    assert spans[0] == (0, 100, "edl_cut")
    assert spans[1] == (100, 262, "edl_cut")
    assert spans[2] == (262, 500, "edl_dissolve")
    assert spans[3] == (500, 600, "edl_gap")        # tail of the file not covered by the EDL


def test_boundaries_to_shots_merges_fragments():
    out = shots.boundaries_to_shots([(1, "cut"), (100, "cut"), (101, "cut"), (250, "dissolve")], 300, min_frames=2)
    assert out[0][0] == 0 and out[0][2] == "start"           # 1-frame opening fragment merged forward
    assert all(e - s >= 2 for s, e, _, _ in out)
    assert out[-1] == (250, 300, "dissolve", "end")
    assert out[0][1] == out[1][0]                              # contiguous coverage


def test_transitions_from_predictions():
    single = np.zeros(50); many = np.zeros(50)
    single[10] = 0.9
    many[20:26] = 0.8; single[23] = 0.7
    spans = shots.transitions_from_predictions(single, many, 0.5)
    assert spans == [(10, 10), (20, 25)]


def test_camera_motion_classes():
    assert visual.classify_camera_motion(0.0001, 0.0, 0, 0, 0, 0, 1) == "static"
    assert visual.classify_camera_motion(0.005, 0.001, 0.005, 0.0002, 0, 0.05, 1) == "pan"
    assert visual.classify_camera_motion(0.005, 0.001, 0.0002, -0.005, 0, 0.05, 1) == "tilt"
    assert visual.classify_camera_motion(0.005, 0.001, 0.003, 0.003, 0, 0.8, 1) == "handheld"
    assert visual.classify_camera_motion(0.002, 0.0005, 0.0001, 0.0001, 0.004, 0.1, 1, 0.9) == "zoom"
    assert visual.classify_camera_motion(0.002, 0.0005, 0.0001, 0.0001, 0.004, 0.1, 1, 0.3) != "zoom"


def test_hue_names():
    assert visual.hue_name(0, 0.5) == "red"
    assert visual.hue_name(120, 0.5) == "green"
    assert visual.hue_name(230, 0.5) == "blue"
    assert visual.hue_name(230, 0.05) == "neutral"


def test_windows_to_segments_and_shot_summary():
    wins = []
    for i in range(20):
        if i < 6:
            g = {"speech": 0.8, "music": 0.1, "ambience": 0.1, "sfx": 0.0, "silence": 0.0}; rms = -25
        elif i < 9:
            g = {"speech": 0.0, "music": 0.0, "ambience": 0.0, "sfx": 0.0, "silence": 0.3}; rms = -80
        else:
            g = {"speech": 0.05, "music": 0.9, "ambience": 0.1, "sfx": 0.0, "silence": 0.0}; rms = -20
        wins.append({"start": float(i), "rms_db": rms, "groups": g,
                     "top": [{"label": "Speech" if i < 6 else "Music", "idx": 0, "score": 0.8}]})
    segs = audio.windows_to_segments(wins, 20.0)
    assert [s["coarse"] for s in segs] == ["speech", "silence", "music"]
    assert segs[0]["start_sec"] == 0.0 and segs[-1]["end_sec"] == 20.0
    sh = [{"start_sec": 0.0, "end_sec": 4.0, "in_type": "start", "out_type": "cut"},
          {"start_sec": 4.0, "end_sec": 12.0, "in_type": "cut", "out_type": "cut"},
          {"start_sec": 12.0, "end_sec": 20.0, "in_type": "cut", "out_type": "end"}]
    tr = [{"start_sec": 0.5, "end_sec": 5.5, "words": [{"w": "hello", "s": 1.0, "e": 1.4}, {"w": "world", "s": 4.5, "e": 5.0}]}]
    audio.summarise_for_shots(sh, segs, tr)
    assert sh[0]["audio_class"] == "speech" and sh[0]["audio_bridge_out"] == 1 and sh[0]["speech_bridge_out"] == 1
    assert sh[0]["transcript_text"] == "hello" and sh[1]["transcript_text"] == "world"
    assert sh[2]["audio_class"] == "music" and sh[2]["audio_bridge_out"] == 0


def test_dominant_colors():
    pix = np.array([[255, 0, 0]] * 70 + [[0, 0, 255]] * 30, dtype=np.uint8)
    cols = visual.dominant_colors(pix, 5)
    assert cols[0]["hex"] == "#0000ff" and abs(cols[0]["frac"] - 0.7) < 0.01   # BGR in -> hex RGB out
