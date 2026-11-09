"""SQLite schema and helpers.

Flat tables.  Frame numbers are the authoritative record for in/out points;
seconds and SMPTE timecodes are derived.  ``end_frame`` is exclusive, so the
shot occupies frames [start_frame, end_frame) and ``duration_frames ==
end_frame - start_frame``.
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import numpy as np

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY,
  path TEXT UNIQUE NOT NULL,          -- absolute source path
  rel_path TEXT,                      -- relative to the source root
  filename TEXT,
  size_bytes INTEGER,
  mtime REAL,
  duration_sec REAL,
  fps REAL, fps_num INTEGER, fps_den INTEGER,
  width INTEGER, height INTEGER, codec TEXT,
  nb_frames INTEGER,
  start_timecode TEXT,                -- SMPTE start TC of the source, if the file carries one
  vfr INTEGER DEFAULT 0,
  has_audio INTEGER DEFAULT 0,
  audio_channels INTEGER, audio_layout TEXT, audio_sample_rate INTEGER, audio_codec TEXT,
  proxy_path TEXT, audio_path TEXT,
  boundary_source TEXT,               -- transnetv2 | pyscenedetect | edl:<file>
  -- layer completion flags (checkpoints)
  l1_done INTEGER DEFAULT 0, l2_done INTEGER DEFAULT 0, l3_done INTEGER DEFAULT 0, l4_done INTEGER DEFAULT 0,
  runtime_proxy REAL, runtime_l1 REAL, runtime_l2 REAL, runtime_l3 REAL, runtime_l4 REAL,
  -- layer 2 file-level audio
  integrated_lufs REAL, loudness_range REAL, true_peak_dbtp REAL, sample_peak_dbfs REAL,
  silence_spans_json TEXT, loudness_envelope_json TEXT,
  language TEXT, language_prob REAL,
  -- layer 4
  shot_count INTEGER, mean_shot_sec REAL, median_shot_sec REAL, min_shot_sec REAL, max_shot_sec REAL,
  cuts_per_minute REAL,
  duration_hist_json TEXT, cut_timeline_json TEXT, trajectories_json TEXT,
  summary TEXT,
  -- outputs
  contact_sheet_path TEXT, json_path TEXT, md_path TEXT,
  error TEXT,
  created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS shots (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  idx INTEGER NOT NULL,               -- 0-based shot index within the file
  start_frame INTEGER NOT NULL,
  end_frame INTEGER NOT NULL,         -- exclusive
  duration_frames INTEGER,
  start_sec REAL, end_sec REAL, duration_sec REAL,
  start_tc TEXT, end_tc TEXT,         -- SMPTE (NDF), offset by the file's start timecode
  fps REAL,
  in_type TEXT, out_type TEXT,        -- start|cut|dissolve|fade|end|edl_<type>
  -- layer 1 visual
  brightness REAL, contrast REAL, saturation REAL,     -- 0..1
  colors_json TEXT,                   -- [{"hex":"#rrggbb","frac":0.31}, ...] top 5
  hue_deg REAL, hue_name TEXT,
  motion_camera REAL, motion_inframe REAL, motion_total REAL,   -- px/frame / frame width, mean
  cam_dx REAL, cam_dy REAL, cam_zoom REAL, cam_jitter REAL,
  camera_motion TEXT,                 -- static|pan|tilt|zoom|tracking|handheld|complex
  complexity_edges REAL, complexity_jpeg REAL,
  phash TEXT,
  key_frame_path TEXT, strip_path TEXT, frames_json TEXT,
  -- layer 2 (audio summarised over the shot's span)
  audio_class TEXT,                   -- speech|music|ambience|silence|sfx|mixed|none
  speech_frac REAL, music_frac REAL, silence_frac REAL,
  audio_bridge_in INTEGER, audio_bridge_out INTEGER,   -- an audio segment runs across the cut
  speech_bridge_in INTEGER, speech_bridge_out INTEGER, -- a transcript segment runs across the cut
  transcript_text TEXT,
  -- layer 3 model pass
  shot_scale TEXT, scale_scores_json TEXT,
  interior_exterior TEXT, day_night TEXT,
  face_count INTEGER, face_size_max REAL, people_count INTEGER,
  description TEXT, editorial TEXT,
  vision_done INTEGER DEFAULT 0, vision_model TEXT,
  UNIQUE(file_id, idx)
);
CREATE INDEX IF NOT EXISTS shots_file ON shots(file_id);
CREATE INDEX IF NOT EXISTS shots_dur ON shots(duration_sec);
CREATE INDEX IF NOT EXISTS shots_scale ON shots(shot_scale);

CREATE TABLE IF NOT EXISTS audio_segments (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  idx INTEGER,
  start_sec REAL, end_sec REAL, duration_sec REAL,
  coarse TEXT,                        -- speech|music|ambience|silence|sfx
  labels_json TEXT,                   -- [{"label":"Speech","score":0.81}, ...]
  rms_db REAL,
  confidence REAL
);
CREATE INDEX IF NOT EXISTS aseg_file ON audio_segments(file_id);

CREATE TABLE IF NOT EXISTS transcripts (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  idx INTEGER,
  start_sec REAL, end_sec REAL,
  text TEXT,
  language TEXT,
  words_json TEXT,                    -- [{"w":"word","s":1.23,"e":1.50,"p":0.9}, ...]
  avg_logprob REAL, no_speech_prob REAL
);
CREATE INDEX IF NOT EXISTS tr_file ON transcripts(file_id);

CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  kind TEXT                           -- audio|visual|scale|camera|light|place|content
);
CREATE TABLE IF NOT EXISTS tag_links (
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL,          -- shot|audio_segment|file
  target_id INTEGER NOT NULL,
  score REAL,
  source TEXT,                        -- panns|clip|flow|yunet|yolo|vlm|edl
  PRIMARY KEY (tag_id, target_type, target_id, source)
);
CREATE INDEX IF NOT EXISTS tl_target ON tag_links(target_type, target_id);

CREATE TABLE IF NOT EXISTS embeddings (
  id INTEGER PRIMARY KEY,
  shot_id INTEGER NOT NULL REFERENCES shots(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  dim INTEGER NOT NULL,
  vector BLOB NOT NULL,               -- float32 little-endian, L2-normalised
  UNIQUE(shot_id, model)
);

CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY,
  started_at TEXT, finished_at TEXT,
  args TEXT, files_done INTEGER DEFAULT 0, notes TEXT
);

CREATE VIRTUAL TABLE IF NOT EXISTS shots_fts USING fts5(
  description, editorial, transcript_text, content='shots', content_rowid='id'
);
CREATE TRIGGER IF NOT EXISTS shots_ai AFTER INSERT ON shots BEGIN
  INSERT INTO shots_fts(rowid, description, editorial, transcript_text)
  VALUES (new.id, new.description, new.editorial, new.transcript_text);
END;
CREATE TRIGGER IF NOT EXISTS shots_ad AFTER DELETE ON shots BEGIN
  INSERT INTO shots_fts(shots_fts, rowid, description, editorial, transcript_text)
  VALUES ('delete', old.id, old.description, old.editorial, old.transcript_text);
END;
CREATE TRIGGER IF NOT EXISTS shots_au AFTER UPDATE ON shots BEGIN
  INSERT INTO shots_fts(shots_fts, rowid, description, editorial, transcript_text)
  VALUES ('delete', old.id, old.description, old.editorial, old.transcript_text);
  INSERT INTO shots_fts(rowid, description, editorial, transcript_text)
  VALUES (new.id, new.description, new.editorial, new.transcript_text);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
  text, content='transcripts', content_rowid='id'
);
CREATE TRIGGER IF NOT EXISTS tr_ai AFTER INSERT ON transcripts BEGIN
  INSERT INTO transcripts_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER IF NOT EXISTS tr_ad AFTER DELETE ON transcripts BEGIN
  INSERT INTO transcripts_fts(transcripts_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;
"""


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=60)
    con.row_factory = sqlite3.Row
    con.executescript(SCHEMA)
    return con


def j(obj) -> str | None:
    return None if obj is None else json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def upsert_file(con: sqlite3.Connection, row: dict) -> int:
    cols = list(row.keys())
    sql = (f"INSERT INTO files ({','.join(cols)}) VALUES ({','.join('?' * len(cols))}) "
           f"ON CONFLICT(path) DO UPDATE SET " +
           ",".join(f"{c}=excluded.{c}" for c in cols if c != "path") +
           ", updated_at=datetime('now')")
    con.execute(sql, [row[c] for c in cols])
    return con.execute("SELECT id FROM files WHERE path=?", (row["path"],)).fetchone()[0]


def update_file(con: sqlite3.Connection, file_id: int, **fields) -> None:
    if not fields:
        return
    sets = ",".join(f"{k}=?" for k in fields)
    con.execute(f"UPDATE files SET {sets}, updated_at=datetime('now') WHERE id=?", [*fields.values(), file_id])


def replace_shots(con: sqlite3.Connection, file_id: int, shots: list[dict]) -> list[int]:
    con.execute("DELETE FROM shots WHERE file_id=?", (file_id,))
    ids = []
    for s in shots:
        cols = list(s.keys())
        cur = con.execute(f"INSERT INTO shots (file_id,{','.join(cols)}) VALUES (?,{','.join('?' * len(cols))})",
                          [file_id, *s.values()])
        ids.append(cur.lastrowid)
    return ids


def update_shot(con: sqlite3.Connection, shot_id: int, **fields) -> None:
    if not fields:
        return
    sets = ",".join(f"{k}=?" for k in fields)
    con.execute(f"UPDATE shots SET {sets} WHERE id=?", [*fields.values(), shot_id])


def tag_id(con: sqlite3.Connection, name: str, kind: str) -> int:
    con.execute("INSERT OR IGNORE INTO tags(name, kind) VALUES (?,?)", (name, kind))
    return con.execute("SELECT id FROM tags WHERE name=?", (name,)).fetchone()[0]


def link_tag(con, name: str, kind: str, target_type: str, target_id: int, score: float | None, source: str) -> None:
    tid = tag_id(con, name, kind)
    con.execute("INSERT OR REPLACE INTO tag_links(tag_id,target_type,target_id,score,source) VALUES (?,?,?,?,?)",
                (tid, target_type, target_id, score, source))


def clear_tags(con, target_type: str, target_ids: list[int], source: str | None = None) -> None:
    if not target_ids:
        return
    q = f"DELETE FROM tag_links WHERE target_type=? AND target_id IN ({','.join('?' * len(target_ids))})"
    args = [target_type, *target_ids]
    if source:
        q += " AND source=?"
        args.append(source)
    con.execute(q, args)


def put_embedding(con, shot_id: int, model: str, vec: np.ndarray) -> None:
    v = np.asarray(vec, dtype=np.float32)
    n = np.linalg.norm(v)
    if n > 0:
        v = v / n
    con.execute("INSERT OR REPLACE INTO embeddings(shot_id, model, dim, vector) VALUES (?,?,?,?)",
                (shot_id, model, int(v.size), v.astype("<f4").tobytes()))


def get_embedding(row) -> np.ndarray:
    return np.frombuffer(row["vector"], dtype="<f4")


def file_rows(con) -> list[sqlite3.Row]:
    return con.execute("SELECT * FROM files ORDER BY rel_path").fetchall()


def shots_for(con, file_id: int) -> list[sqlite3.Row]:
    return con.execute("SELECT * FROM shots WHERE file_id=? ORDER BY idx", (file_id,)).fetchall()
