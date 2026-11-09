# Footage catalogue (`fcat`)

Shot-by-shot structural catalogue of a footage archive, built for editing reference and
for a downstream "play the archive" tool.  One SQLite database plus per-file JSON and
Markdown, thumbnails/filmstrips/contact sheets, and a static HTML browser.  Nothing is ever
written into the source folder.

```
source  /Volumes/Super/CollectedFootage          (read only, recursed)
output  /Volumes/G-DRIVE PRO SSD/FootageCatalogue/
          catalogue.sqlite     database (WAL)
          proxies/             480p proxies + 32 kHz mono WAVs (kept so the HTML can play shots)
          thumbs/<file>/       shot_NNNN_key.jpg, shot_NNNN_f0..f3.jpg, shot_NNNN_strip.jpg, contact_sheet.jpg
          json/<file>.json     complete portable record per file
          markdown/<file>.md   human-readable record per file
          html/index.html      browsable index (open directly, no server)
          logs/                run logs + timings.csv (per-file runtimes, realtime factor)
          models/              downloaded weights (PANNs, YuNet)
```

## Install (macOS)

Requires Python 3.10+ and ffmpeg on PATH (`brew install ffmpeg`).

```bash
cd catalogue
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[models]"          # core + TransNetV2 + CLIP + PANNs + faster-whisper + SmolVLM
# optional extras
pip install -e ".[people]"          # YOLOv8n person counting (ultralytics)
pip install -e ".[claude]"          # descriptions via the Claude API (needs ANTHROPIC_API_KEY)
```

If `torch`/`transnetv2-pytorch` will not install, `pip install -e .` alone still works: shot
detection falls back to PySceneDetect, audio segmentation to energy only, and the model
pass is skipped.  Everything in Layer 1 and Layer 4 is plain OpenCV/numpy.

Model weights download on first use into `models/` (PANNs CNN14 ~330 MB from Zenodo,
YuNet ~230 KB from GitHub) or the Hugging Face cache (CLIP ViT-B/32 ~600 MB, Whisper
`small` ~480 MB, SmolVLM-500M ~1 GB).  TransNetV2 weights ship inside its wheel.

## Run

```bash
# first file only, everything except the model pass
fcat run --limit 1

# one specific file
fcat run "/Volumes/Super/CollectedFootage/some/clip.mov"

# the whole archive (resumable: kill it and run the same command again)
fcat run

# Layer 3 model pass over everything already analysed (resumable, separately runnable).
# Default: CLIP + faces + SmolVLM one-line descriptions (local, free, slow: several seconds per shot on CPU)
fcat vision
fcat vision --describe off            # CLIP + faces only (fast)
fcat vision --describe claude         # descriptions + editorial lines via the Claude API (ANTHROPIC_API_KEY)
fcat similar 3:12                     # nearest shots to file 3, shot 13, by CLIP embedding

fcat status                           # progress per file
fcat html                             # regenerate the HTML index
fcat export                           # rewrite JSON/Markdown/contact sheets from the DB
```

`--source` and `--out` default to the two paths above.  Every slow pass has a flag:
`--no-flow` (optical flow), `--no-audio`, `--no-tagger` (PANNs), `--no-transcribe`
(Whisper), `--no-embed` (CLIP), `--no-faces`, `--people`, `--describe off|smolvlm|claude`,
`--vision` (run Layer 3 inside `run`).  `--force` redoes layers already marked done.
`--whisper-model base` is several times faster than the default `small`.

### Resource rules as implemented

* Analysis runs on a 480p H.264 proxy made with ffmpeg; the 4K original is only decoded
  once (proxy + audio extraction + ffmpeg loudness pass).  On macOS the proxy decode uses
  VideoToolbox (`--hwaccel none` to disable).
* CFR sources are passed through frame-for-frame, so proxy frame *i* is source frame *i*
  and the in/out frame numbers are exact.  VFR sources are resampled to a constant native
  rate; the log says when the proxy frame count differs from the container's claim.
* Frames are streamed with OpenCV; a 100-frame 48x27 window is the most TransNetV2 holds.
  Audio is read in 1 s blocks.  Nothing holds a whole file.
* One file at a time.  Each layer commits in one SQLite transaction and sets a flag
  (`l1_done … l4_done`); the model pass commits every 8 shots with per-shot
  `vision_done`.  A killed run restarts at the first unfinished layer of the file.
* Model pass: 1–2 sampled frames per shot (`--vision-frames`), shots under 0.5 s skipped
  (`--vision-min-sec`).  SmolVLM is the slow part: ~13 s per shot on a 4-core x86 CPU
  here, expected a few seconds per shot on Apple Silicon (MPS).  Budget accordingly or run
  `fcat vision --describe off` first and add descriptions in a later pass.
* Per-file runtimes go to the log and `logs/timings.csv`; after three files the log prints
  the realtime factor and the estimated remaining time for the rest of the archive.

## Layers

**Layer 1 (per shot, computed).**  Boundaries from TransNetV2 (streamed, windowed as in
the reference implementation), PySceneDetect fallback, or a DaVinci Resolve CMX3600 EDL
(`<stem>.edl` next to the file or in `--edl-dir`) which overrides detection.  Resolve's
Scene Cut Detection export is read directly: source-column TCs relative to the file's own
start timecode when they fit the file, otherwise record-column TCs relative to the first
event (`--edl-tc source|record` forces one).  Event types C/D/W become `edl_cut`,
`edl_dissolve`, `edl_wipe`; uncovered stretches become `edl_gap` shots.  Hard cuts are snapped to the largest inter-frame difference
within ±3 frames of the network's prediction; boundaries are typed `cut | dissolve |
fade` from the transition span length and luma.  Per shot: start/end frame (end
exclusive), seconds, SMPTE TC offset by the file's start timecode, native fps as a
rational, brightness/contrast/saturation (0–1), five dominant colours (k-means) with
fractions, circular-mean hue and a hue name, Farneback optical flow at 320 px split into
camera motion (RANSAC similarity fit on textured pixels) and in-frame residual, camera
dx/dy/zoom and directional coherence, a heuristic camera-motion class, edge density and
JPEG-size complexity, a 64-bit pHash of the key frame, key frame + 4-frame filmstrip.

**Layer 2 (audio, its own timeline).**  ffmpeg `ebur128`: integrated LUFS, LRA, true
and sample peak, 1 Hz short-term envelope; `silencedetect` spans; channel layout from
ffprobe.  2 s / 1 s-hop windows tagged by PANNs CNN14 (AudioSet, 527 labels) grouped into
speech / music / ambience / sfx / silence, smoothed and merged into segments with the top
fine labels.  faster-whisper transcription with word timestamps and language id.  Each
shot gets the dominant audio class, speech/music/silence fractions, the words spoken
inside it, and flags for audio (and speech) continuing across its in and out cuts.  Files
without an audio track are flagged `has_audio=0`, not errors.

**Layer 3 (per shot, optional models).**  CLIP ViT-B/32 embedding (L2-normalised
float32 blob in `embeddings`) and zero-shot shot scale (wide/medium/close-up, raw
five-way scores kept), interior/exterior, day/night (blended with Layer 1 brightness).
Face count and largest face size (YuNet; faces refine the scale).  People count (YOLOv8n
if installed, else face count).  One-line description from SmolVLM-500M (one key frame, one
plain question; the 500M model cannot follow a two-part instruction) or from Claude.  The
one-sentence **editorial reading is rule-based**, composed from scale, camera motion,
duration, faces, place, light, motion energy and the audio class, so every shot gets one
even without a VLM; with `--describe claude` the model writes it instead.  Camera-motion
type comes from Layer 1 flow.

**Layer 4 (per file, derived).**  Shot count, mean/median/min/max shot length, cuts per
minute, duration histogram, cut-rhythm timeline (cut times, cuts per 30 s window, shot
length sequence), per-shot colour/brightness/motion trajectories plus 1 Hz
brightness/saturation/motion series, and a rule-based editorial paragraph.

## Database

Flat tables: `files`, `shots`, `audio_segments`, `transcripts` (segment rows with
word-level JSON), `tags` + `tag_links` (one vocabulary across picture and audio labels,
many-to-many to shots / audio segments / files), `embeddings`, `runs`.  FTS5 tables
`shots_fts` (description, editorial, transcript_text) and `transcripts_fts` (text) are
kept in sync by triggers:

```sql
SELECT s.* FROM shots s JOIN shots_fts f ON f.rowid = s.id WHERE shots_fts MATCH 'harbour';
```

Every `shots` row is directly usable by the assembly tool: `start_frame`, `end_frame`
(exclusive), `fps` (and `files.fps_num/fps_den`), `start_tc`/`end_tc`, `duration_sec`,
plus the queryable fields (scale, camera_motion, audio_class, brightness, hue_name,
motion_*, face_count, …).  Similarity search: read `embeddings.vector` as `<f4` and dot
it against a query vector.

## Running it

The pipeline has to run on the machine that mounts the drives.  This code was written and
tested in a Linux container on synthetic clips and one real clip; the first run on the
archive itself is `fcat run --limit 1` on the Mac, then inspect `html/index.html`, the
contact sheet and the JSON before `fcat run` on everything.  Untested so far: Apple
Silicon (MPS) and VideoToolbox decode, 4K decode speed, variable-frame-rate phone footage,
real Resolve EDL exports, the Claude description backend, YOLO people counting.

## Design notes

* **dvt** (Distant Viewing Toolkit 1.1) was evaluated and not used as the spine.  It is a
  thin set of annotators (its own TransNetV2 port, MTCNN faces, EfficientNet embedding)
  that loads whole videos into memory and fetches weights from its own GitHub releases.
  The same TransNetV2 model is available as `transnetv2-pytorch` with the weights in the
  wheel, which this package feeds in a streaming fashion.  **PyCinemetrics** is a PyQt
  desktop application, not a library, and is not on PyPI.
* YAMNet needs TensorFlow; PANNs (PyTorch) is used instead.
* Timecodes are non-drop-frame.  Frame numbers are the authoritative record.
