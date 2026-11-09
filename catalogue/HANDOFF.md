# Hand-off: running the footage catalogue on the Mac

Paste this into a Claude Code session running **on the Mac** (desktop app or `claude` in
Terminal), or follow it by hand.  The code is on branch `claude/wonderful-keller-nnbe13`.

Goal: catalogue every video under `/Volumes/Super/CollectedFootage` (read only) into
`/Volumes/G-DRIVE PRO SSD/FootageCatalogue/` with the `fcat` pipeline in `catalogue/`.
Never write into the source folder.

1. Install (Python 3.10+, ffmpeg via Homebrew):
   ```bash
   python3 -m venv ~/fcat-env && source ~/fcat-env/bin/activate
   pip install "footage-catalogue[models] @ git+https://github.com/vertov/LIBELLULA.git@claude/wonderful-keller-nnbe13#subdirectory=catalogue"
   ```
2. Keep the Mac awake: `caffeinate -d -i &`
3. One file first: `fcat run --limit 1`.  Open
   `/Volumes/G-DRIVE PRO SSD/FootageCatalogue/html/index.html`, check the contact sheet,
   the shot table and the JSON in `json/`.  The log in `logs/` shows runtime per layer.
4. If it looks right: `fcat run` (whole archive; Layers 1, 2, 4; resumable, just rerun it).
5. Then the model pass: `fcat vision` (CLIP, faces, SmolVLM descriptions; slow; resumable).
   `fcat vision --describe off` first if time is short, descriptions can be added later.
6. `fcat status` shows progress.  `fcat html` regenerates the browser.

Known unknowns on first Mac run: Apple Silicon (MPS) for CLIP/SmolVLM, VideoToolbox
proxy decode (`--hwaccel none` if ffmpeg errors), 4K decode speed, VFR phone clips.
If TransNetV2/torch refuse to install, `pip install "footage-catalogue @ git+...#subdirectory=catalogue"`
without `[models]` still runs Layers 1 and 4 with PySceneDetect and energy-only audio.
