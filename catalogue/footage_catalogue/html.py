"""Static HTML index generated from the database.  No server: data is embedded as JS."""
from __future__ import annotations

import html
import json
import sqlite3
from pathlib import Path

from .config import Config
from .pipeline import build_record, _tag
from .probe import ProbeInfo, sec_to_hms

CSS = """
:root{--bg:#141416;--panel:#1e1e22;--line:#2c2c31;--fg:#e6e6e6;--muted:#9a9aa3;--acc:#58a6ff;--chip:#2a2a30}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,Helvetica,Arial,sans-serif}
a{color:var(--acc);text-decoration:none}header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;gap:18px;align-items:baseline;flex-wrap:wrap}
header h1{font-size:18px;margin:0}header .muted{color:var(--muted)}main{padding:16px 20px}
.filters{display:flex;flex-wrap:wrap;gap:10px 16px;align-items:end;background:var(--panel);padding:12px;border:1px solid var(--line);border-radius:8px;margin-bottom:14px}
.filters label{display:flex;flex-direction:column;font-size:12px;color:var(--muted);gap:3px}
.filters input,.filters select{background:#111;color:var(--fg);border:1px solid var(--line);border-radius:4px;padding:4px 6px;font-size:13px}
.filters input[type=text]{width:220px}.filters input[type=number]{width:70px}.count{color:var(--muted);font-size:12px;margin-left:auto}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:6px;overflow:hidden;cursor:pointer}
.card:hover{border-color:var(--acc)}.card img{width:100%;display:block;aspect-ratio:16/9;object-fit:cover;background:#000}
.card .cap{padding:6px 8px;font-size:12px}.card .cap b{font-weight:600}.card .cap .muted{color:var(--muted)}
.chips{display:flex;flex-wrap:wrap;gap:4px;margin-top:4px}.chip{background:var(--chip);border-radius:3px;padding:1px 6px;font-size:11px;color:#cfcfd6}
.swatch{display:inline-block;width:14px;height:10px;border-radius:2px;margin-right:2px;vertical-align:middle}
table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);font-size:13px;vertical-align:top}
th{color:var(--muted);font-weight:500;cursor:pointer;user-select:none}tr:hover td{background:#1a1a1f}
#detail{position:fixed;top:0;right:0;width:min(640px,100%);height:100%;background:var(--panel);border-left:1px solid var(--line);overflow:auto;padding:16px;display:none;z-index:10}
#detail.open{display:block}#detail .close{float:right;cursor:pointer;color:var(--muted);font-size:20px}
#detail img.strip{width:100%;display:block;margin:8px 0;border-radius:4px}#detail dl{display:grid;grid-template-columns:150px 1fr;gap:3px 10px;font-size:13px}
#detail dt{color:var(--muted)}#detail dd{margin:0;word-break:break-word}#detail video{width:100%;background:#000;border-radius:4px}
.summary{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px 14px;margin-bottom:14px;max-width:1100px}
.sheet{max-width:100%;border-radius:6px;border:1px solid var(--line);margin-bottom:14px}
.timeline{position:relative;height:38px;background:#0d0d10;border:1px solid var(--line);border-radius:4px;margin:8px 0 14px;overflow:hidden}
.timeline .shot{position:absolute;top:0;height:18px;border-right:1px solid #000;cursor:pointer}.timeline .shot:hover{outline:1px solid #fff}
.timeline .aseg{position:absolute;top:20px;height:16px;opacity:.85}.legend{font-size:11px;color:var(--muted);margin-bottom:10px}
.legend span{display:inline-block;margin-right:10px}.legend i{display:inline-block;width:10px;height:10px;margin-right:4px;vertical-align:middle;border-radius:2px}
.transcript{font-size:13px;max-height:220px;overflow:auto;background:#0d0d10;padding:8px 10px;border-radius:4px;border:1px solid var(--line)}
.transcript span{cursor:pointer}.transcript span:hover{color:var(--acc)}h2{font-size:15px;margin:18px 0 8px;color:var(--muted);font-weight:500}
"""

AUDIO_COLORS = {"speech": "#e0a040", "music": "#8e6ad6", "ambience": "#3f9f6f", "sfx": "#d05050", "silence": "#444", "sound": "#777", "mixed": "#999", "none": "#222"}

JS_COMMON = r"""
const AC = %s;
const esc = s => String(s==null?'':s).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fmt = (x, d=2) => x==null ? '' : (+x).toFixed(d);
const hms = s => { if (s==null) return ''; s=+s; const h=Math.floor(s/3600), m=Math.floor(s%%3600/60), sec=(s%%60); return (h?h+':':'')+String(m).padStart(2,'0')+':'+sec.toFixed(2).padStart(5,'0'); };
function swatches(cols){ return (cols||[]).slice(0,5).map(c=>`<span class="swatch" style="background:${c.hex}" title="${c.hex} ${Math.round(c.frac*100)}%%"></span>`).join(''); }
function card(s, withFile){
  const img = s.key ? `${s.thumbs}/${s.key}` : '';
  return `<div class="card" data-id="${s.id}">
    <img loading="lazy" src="${img}" alt="">
    <div class="cap"><b>#${s.idx+1}</b> <span class="muted">${esc(s.start_tc||hms(s.start_sec))}</span> · ${fmt(s.duration_sec)}s
      ${withFile?`<div class="muted" style="font-size:11px">${esc(s.file)}</div>`:''}
      <div class="chips">${s.in_type&&s.in_type!=='start'&&s.in_type!=='cut'?`<span class="chip">${esc(s.in_type)}</span>`:''}
      ${s.camera_motion?`<span class="chip">${esc(s.camera_motion)}</span>`:''}${s.shot_scale?`<span class="chip">${esc(s.shot_scale)}</span>`:''}
      ${s.audio_class&&s.audio_class!=='none'?`<span class="chip" style="border-left:3px solid ${AC[s.audio_class]||'#777'}">${esc(s.audio_class)}</span>`:''}
      ${s.face_count?`<span class="chip">${s.face_count} face${s.face_count>1?'s':''}</span>`:''}</div>
      <div style="margin-top:4px">${swatches(s.colors)}</div>
    </div></div>`;
}
function detail(s){
  const d = document.getElementById('detail');
  const frames = (s.frames||[]).map(f=>`<img src="${s.thumbs}/${f}" style="width:24%%;margin-right:1%%;border-radius:3px">`).join('');
  const strip = s.strip ? `<img class="strip" src="${s.thumbs}/${s.strip}">` : frames;
  const vid = s.proxy ? `<video controls preload="none" src="${s.proxy}#t=${s.start_sec},${s.end_sec}"></video>` : '';
  const rows = [
    ['file', s.file], ['shot', `#${s.idx+1}`], ['in / out TC', `${s.start_tc||''} → ${s.end_tc||''}`],
    ['in / out frame', `${s.start_frame} → ${s.end_frame} (excl.)  ${s.duration_frames} frames @ ${s.fps} fps`],
    ['in / out sec', `${fmt(s.start_sec,3)} → ${fmt(s.end_sec,3)}  (${fmt(s.duration_sec)} s)`],
    ['transition in / out', `${s.in_type||''} / ${s.out_type||''}`],
    ['camera motion', `${s.camera_motion||''}  cam ${fmt(s.motion_camera,4)}  in-frame ${fmt(s.motion_inframe,4)}  total ${fmt(s.motion_total,4)}  dx ${fmt(s.cam_dx,4)} dy ${fmt(s.cam_dy,4)} zoom ${fmt(s.cam_zoom,4)} jitter ${fmt(s.cam_jitter,2)}`],
    ['brightness / contrast / saturation', `${fmt(s.brightness,3)} / ${fmt(s.contrast,3)} / ${fmt(s.saturation,3)}`],
    ['dominant colours', swatches(s.colors) + ' ' + (s.hue_name||'') + (s.hue_deg!=null?` (${Math.round(s.hue_deg)}°)`:'')],
    ['complexity', `edges ${fmt(s.complexity_edges,4)}  jpeg ${fmt(s.complexity_jpeg,3)} B/px`],
    ['phash', s.phash||''],
    ['shot scale', s.shot_scale ? `${s.shot_scale} ${s.scale_scores?'('+esc(s.scale_scores.raw)+')':''}` : ''],
    ['interior / exterior', s.interior_exterior||''], ['day / night', s.day_night||''],
    ['faces / people', s.face_count!=null ? `${s.face_count} faces (max ${fmt(s.face_size_max,2)} of frame)  ${s.people_count!=null?s.people_count+' people':''}` : ''],
    ['audio', s.audio_class ? `${s.audio_class}  speech ${fmt(s.speech_frac)}  music ${fmt(s.music_frac)}  silence ${fmt(s.silence_frac)}` : ''],
    ['audio across cut', s.audio_class ? `in: ${s.audio_bridge_in?'yes':'no'}  out: ${s.audio_bridge_out?'yes':'no'}  (speech in/out: ${s.speech_bridge_in?'yes':'no'}/${s.speech_bridge_out?'yes':'no'})` : ''],
    ['transcript', s.transcript_text||''],
    ['description', s.description||''], ['editorial', s.editorial||''],
    ['tags', (s.tags||[]).map(t=>`<span class="chip">${esc(t.tag)}</span>`).join(' ')],
    ['vision model', s.vision_model||''],
  ].filter(r=>r[1]!=='' && r[1]!=null).map(r=>`<dt>${r[0]}</dt><dd>${r[1]}</dd>`).join('');
  d.innerHTML = `<span class="close" onclick="document.getElementById('detail').classList.remove('open')">×</span>
    <h3 style="margin:0 0 6px">${esc(s.file)} — shot #${s.idx+1}</h3>${strip}${vid}<dl>${rows}</dl>`;
  d.classList.add('open');
}
document.addEventListener('click', e => {
  const c = e.target.closest('.card, .shot, tr[data-id]'); if (!c) return;
  const s = SHOTS.find(x => x.id == c.dataset.id); if (s) detail(s);
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') document.getElementById('detail').classList.remove('open'); });
"""

INDEX_JS = r"""
const FILES = window.FILES, SHOTS = window.SHOTS;
function renderFiles(){
  const tb = document.querySelector('#files tbody');
  tb.innerHTML = FILES.map(f=>`<tr><td><a href="files/${f.page}">${esc(f.filename)}</a><div class="muted" style="font-size:11px">${esc(f.rel_path)}</div></td>
    <td>${hms(f.duration_sec)}</td><td>${f.width}x${f.height}</td><td>${fmt(f.fps,3)}</td><td>${f.shot_count??''}</td>
    <td>${fmt(f.mean_shot_sec,1)}</td><td>${fmt(f.median_shot_sec,1)}</td><td>${fmt(f.cuts_per_minute,1)}</td>
    <td>${f.has_audio?(f.language||'audio'):'<span class="muted">none</span>'}</td><td>${fmt(f.integrated_lufs,1)}</td>
    <td>${f.l1_done?'1':''}${f.l2_done?'2':''}${f.l3_done?'3':''}${f.l4_done?'4':''}${f.error?' <span style="color:#d05050">err</span>':''}</td></tr>`).join('');
}
function applyFilters(){
  const q = document.getElementById('q').value.trim().toLowerCase();
  const dmin = +document.getElementById('dmin').value || 0, dmax = +document.getElementById('dmax').value || 1e9;
  const scale = document.getElementById('scale').value, cam = document.getElementById('cam').value, hue = document.getElementById('hue').value;
  const aud = document.getElementById('aud').value, place = document.getElementById('place').value, tod = document.getElementById('tod').value;
  const bmin = +document.getElementById('bmin').value || 0, bmax = +document.getElementById('bmax').value || 1;
  const mmin = +document.getElementById('mmin').value || 0;
  const faces = document.getElementById('faces').value;
  const file = document.getElementById('file').value;
  const sort = document.getElementById('sort').value;
  let out = SHOTS.filter(s =>
    s.duration_sec >= dmin && s.duration_sec <= dmax &&
    (!scale || s.shot_scale === scale) && (!cam || s.camera_motion === cam) && (!hue || s.hue_name === hue) &&
    (!aud || s.audio_class === aud) && (!place || s.interior_exterior === place) && (!tod || s.day_night === tod) &&
    (s.brightness==null || (s.brightness >= bmin && s.brightness <= bmax)) && ((s.motion_total||0) >= mmin) &&
    (!faces || (faces==='yes' ? s.face_count>0 : !s.face_count)) && (!file || s.file === file) &&
    (!q || `${s.transcript_text||''} ${s.description||''} ${s.editorial||''} ${s.file} ${(s.tags||[]).map(t=>t.tag).join(' ')}`.toLowerCase().includes(q)));
  const key = {dur:'duration_sec', bright:'brightness', motion:'motion_total', sat:'saturation', hue:'hue_deg', file:'file'}[sort];
  if (key) out.sort((a,b)=> key==='file' ? (a.file.localeCompare(b.file)||a.idx-b.idx) : ((b[key]??-1)-(a[key]??-1)));
  document.getElementById('count').textContent = `${out.length} / ${SHOTS.length} shots`;
  document.getElementById('grid').innerHTML = out.slice(0, 600).map(s=>card(s, true)).join('') + (out.length>600?`<div class="muted">… ${out.length-600} more; narrow the filters</div>`:'');
}
function fillSelect(id, key){
  const vals = [...new Set(SHOTS.map(s=>s[key]).filter(Boolean))].sort();
  const el = document.getElementById(id); el.innerHTML = '<option value="">any</option>' + vals.map(v=>`<option>${esc(v)}</option>`).join('');
}
renderFiles(); ['scale','cam','hue','aud','place','tod'].forEach((id,i)=>fillSelect(id, ['shot_scale','camera_motion','hue_name','audio_class','interior_exterior','day_night'][i]));
fillSelect('file','file');
document.querySelectorAll('.filters input, .filters select').forEach(el=>el.addEventListener('input', applyFilters));
applyFilters();
"""

FILE_JS = r"""
const SHOTS = window.SHOTS, F = window.FILE, SEGS = window.SEGS, TR = window.TR;
function timeline(){
  const el = document.getElementById('tl'); const D = F.duration_sec || 1;
  el.innerHTML = SHOTS.map(s=>`<div class="shot" data-id="${s.id}" title="#${s.idx+1} ${fmt(s.duration_sec)}s" style="left:${100*s.start_sec/D}%;width:${100*s.duration_sec/D}%;background:${(s.colors&&s.colors[0]&&s.colors[0].hex)||'#555'}"></div>`).join('')
    + SEGS.map(a=>`<div class="aseg" title="${esc(a.coarse)} ${fmt(a.start_sec,1)}–${fmt(a.end_sec,1)}" style="left:${100*a.start_sec/D}%;width:${100*a.duration_sec/D}%;background:${AC[a.coarse]||'#777'}"></div>`).join('');
}
function render(){
  const q = document.getElementById('q').value.trim().toLowerCase();
  const dmin = +document.getElementById('dmin').value || 0, dmax = +document.getElementById('dmax').value || 1e9;
  const aud = document.getElementById('aud').value, cam = document.getElementById('cam').value, scale = document.getElementById('scale').value;
  const out = SHOTS.filter(s => s.duration_sec>=dmin && s.duration_sec<=dmax && (!aud||s.audio_class===aud) && (!cam||s.camera_motion===cam) && (!scale||s.shot_scale===scale)
    && (!q || `${s.transcript_text||''} ${s.description||''} ${s.editorial||''}`.toLowerCase().includes(q)));
  document.getElementById('count').textContent = `${out.length} / ${SHOTS.length} shots`;
  document.getElementById('grid').innerHTML = out.map(s=>card(s,false)).join('');
  document.querySelector('#shots tbody').innerHTML = out.map(s=>`<tr data-id="${s.id}"><td>${s.idx+1}</td><td>${esc(s.start_tc||'')}</td><td>${esc(s.end_tc||'')}</td><td>${s.start_frame}</td><td>${s.end_frame}</td><td>${fmt(s.duration_sec)}</td>
    <td>${esc(s.in_type)}</td><td>${esc(s.camera_motion||'')}</td><td>${esc(s.shot_scale||'')}</td><td>${fmt(s.brightness)}</td><td>${fmt(s.saturation)}</td><td>${swatches(s.colors)}</td>
    <td>${fmt(s.motion_total,4)}</td><td>${esc(s.audio_class||'')}</td><td>${esc((s.description||s.transcript_text||'').slice(0,90))}</td></tr>`).join('');
}
function fillSelect(id, key){ const vals=[...new Set(SHOTS.map(s=>s[key]).filter(Boolean))].sort(); const el=document.getElementById(id); el.innerHTML='<option value="">any</option>'+vals.map(v=>`<option>${esc(v)}</option>`).join(''); }
['aud','cam','scale'].forEach((id,i)=>fillSelect(id, ['audio_class','camera_motion','shot_scale'][i]));
document.querySelectorAll('.filters input, .filters select').forEach(el=>el.addEventListener('input', render));
document.getElementById('transcript').innerHTML = TR.map(t=>`<span data-t="${t.start_sec}" title="${hms(t.start_sec)}">${esc(t.text)}</span>`).join(' ');
document.getElementById('transcript').addEventListener('click', e=>{ const t=e.target.dataset.t; if(t==null) return; const s=SHOTS.find(x=>x.start_sec<=+t && x.end_sec>+t); if(s) detail(s); });
timeline(); render();
"""


def _shot_light(s: dict, f: dict, thumbs_rel: str, proxy_rel: str | None) -> dict:
    keep = ("id", "idx", "start_frame", "end_frame", "duration_frames", "start_sec", "end_sec", "duration_sec", "start_tc", "end_tc",
            "fps", "in_type", "out_type", "brightness", "contrast", "saturation", "colors", "hue_deg", "hue_name", "motion_camera",
            "motion_inframe", "motion_total", "cam_dx", "cam_dy", "cam_zoom", "cam_jitter", "camera_motion", "complexity_edges",
            "complexity_jpeg", "phash", "audio_class", "speech_frac", "music_frac", "silence_frac", "audio_bridge_in",
            "audio_bridge_out", "speech_bridge_in", "speech_bridge_out", "transcript_text", "shot_scale", "scale_scores",
            "interior_exterior", "day_night", "face_count", "face_size_max", "people_count", "description", "editorial",
            "vision_model", "tags", "frames")
    d = {k: s.get(k) for k in keep}
    d["key"] = s.get("key_frame")
    d["strip"] = s.get("strip_path")
    d["file"] = f["filename"]
    d["file_id"] = f["id"]
    d["thumbs"] = thumbs_rel
    d["proxy"] = proxy_rel
    return d


def _page(title: str, body: str, js: str, data_js: str) -> str:
    return (f"<!doctype html><html><head><meta charset='utf-8'><title>{html.escape(title)}</title>"
            f"<meta name='viewport' content='width=device-width,initial-scale=1'><style>{CSS}</style></head><body>"
            f"{body}<div id='detail'></div><script>{data_js}</script><script>{JS_COMMON % json.dumps(AUDIO_COLORS)}</script>"
            f"<script>{js}</script></body></html>")


def build_site(con: sqlite3.Connection, cfg: Config) -> Path:
    out = cfg.html_dir
    (out / "files").mkdir(parents=True, exist_ok=True)
    files_rows = con.execute("SELECT * FROM files WHERE l1_done=1 ORDER BY rel_path").fetchall()
    all_shots = []
    files_light = []
    for fr in files_rows:
        rec = build_record(con, fr["id"])
        f = rec["file"]
        tag = Path(f["proxy_path"]).stem if f.get("proxy_path") else f"{f['id']:05d}"
        thumbs_rel_file = f"../../thumbs/{tag}"
        thumbs_rel_index = f"../thumbs/{tag}"
        proxy_exists = bool(f.get("proxy_path")) and Path(f["proxy_path"]).exists()
        proxy_rel_file = f"../../proxies/{Path(f['proxy_path']).name}" if proxy_exists else None
        proxy_rel_index = f"../proxies/{Path(f['proxy_path']).name}" if proxy_exists else None
        page = f"{tag}.html"
        files_light.append({k: f.get(k) for k in ("id", "filename", "rel_path", "duration_sec", "width", "height", "fps", "shot_count",
                                                  "mean_shot_sec", "median_shot_sec", "cuts_per_minute", "has_audio", "language",
                                                  "integrated_lufs", "l1_done", "l2_done", "l3_done", "l4_done", "error")} | {"page": page})
        shots_file = [_shot_light(s, f, thumbs_rel_file, proxy_rel_file) for s in rec["shots"]]
        all_shots += [_shot_light(s, f, thumbs_rel_index, proxy_rel_index) for s in rec["shots"]]
        # per-file page
        hist = f.get("duration_hist") or {}
        hist_txt = ", ".join(f"{l}: {c}" for l, c in zip(hist.get("labels", []), hist.get("counts", [])))
        legend = "".join(f"<span><i style='background:{c}'></i>{k}</span>" for k, c in AUDIO_COLORS.items() if k in {a['coarse'] for a in rec['audio_segments']})
        body = f"""
<header><h1><a href="../index.html">Catalogue</a> / {html.escape(f['filename'])}</h1>
<span class="muted">{f['width']}x{f['height']} · {f['fps']:.3f} fps ({f['fps_num']}/{f['fps_den']}) · {sec_to_hms(f['duration_sec'])} · {f['nb_frames']} frames · {html.escape(f['codec'] or '')}
· audio {html.escape(f['audio_layout'] or 'none')}{(' · start TC ' + f['start_timecode']) if f.get('start_timecode') else ''} · boundaries: {html.escape(f.get('boundary_source') or '')}</span></header>
<main>
<div class="summary"><div>{html.escape(f.get('summary') or '')}</div>
<div class="muted" style="margin-top:6px;font-size:12px">shots {f.get('shot_count')} · mean {f.get('mean_shot_sec')} s · median {f.get('median_shot_sec')} s · cuts/min {f.get('cuts_per_minute')} · histogram: {hist_txt}
{f" · {f.get('integrated_lufs')} LUFS, LRA {f.get('loudness_range')} LU, true peak {f.get('true_peak_dbtp')} dBTP" if f.get('integrated_lufs') is not None else ''}</div>
<div class="muted" style="font-size:12px;margin-top:4px"><code>{html.escape(f['path'])}</code> · <a href="../../json/{tag}.json">JSON</a> · <a href="../../markdown/{tag}.md">Markdown</a></div></div>
<img class="sheet" src="{thumbs_rel_file}/contact_sheet.jpg">
<div class="timeline" id="tl"></div><div class="legend">top row: shots (dominant colour) · bottom row: audio segments {legend}</div>
<div class="filters">
 <label>search transcript / description<input type="text" id="q"></label>
 <label>min s<input type="number" id="dmin" step="0.1"></label><label>max s<input type="number" id="dmax" step="0.1"></label>
 <label>audio<select id="aud"></select></label><label>camera<select id="cam"></select></label><label>scale<select id="scale"></select></label>
 <span class="count" id="count"></span></div>
<div class="grid" id="grid"></div>
<h2>Shot list</h2>
<table id="shots"><thead><tr><th>#</th><th>in TC</th><th>out TC</th><th>in f</th><th>out f</th><th>dur s</th><th>in</th><th>camera</th><th>scale</th><th>bright</th><th>sat</th><th>colours</th><th>motion</th><th>audio</th><th>text</th></tr></thead><tbody></tbody></table>
<h2>Transcript{(' (' + f['language'] + ')') if f.get('language') else ''}</h2><div class="transcript" id="transcript"></div>
</main>"""
        data = (f"window.FILE={json.dumps({k: f.get(k) for k in ('id', 'filename', 'duration_sec')})};"
                f"window.SHOTS={json.dumps(shots_file)};window.SEGS={json.dumps(rec['audio_segments'])};"
                f"window.TR={json.dumps([{k: t[k] for k in ('start_sec', 'end_sec', 'text')} for t in rec['transcript']])};")
        (out / "files" / page).write_text(_page(f["filename"], body, FILE_JS, data), encoding="utf-8")

    total_dur = sum((f.get("duration_sec") or 0) for f in files_light)
    body = f"""
<header><h1>Footage catalogue</h1><span class="muted">{len(files_light)} files · {len(all_shots)} shots · {sec_to_hms(total_dur)[:-4]} · source {html.escape(str(cfg.source_root))}</span></header>
<main>
<h2>Files</h2>
<table id="files"><thead><tr><th>file</th><th>duration</th><th>size</th><th>fps</th><th>shots</th><th>mean s</th><th>median s</th><th>cuts/min</th><th>audio</th><th>LUFS</th><th>layers</th></tr></thead><tbody></tbody></table>
<h2>Shots</h2>
<div class="filters">
 <label>search transcript / description / tags<input type="text" id="q"></label>
 <label>file<select id="file"></select></label>
 <label>min s<input type="number" id="dmin" step="0.1"></label><label>max s<input type="number" id="dmax" step="0.1"></label>
 <label>scale<select id="scale"></select></label><label>camera<select id="cam"></select></label><label>hue<select id="hue"></select></label>
 <label>sound<select id="aud"></select></label><label>place<select id="place"></select></label><label>light<select id="tod"></select></label>
 <label>faces<select id="faces"><option value="">any</option><option value="yes">with faces</option><option value="no">no faces</option></select></label>
 <label>brightness ≥<input type="number" id="bmin" step="0.05" min="0" max="1"></label><label>≤<input type="number" id="bmax" step="0.05" min="0" max="1"></label>
 <label>motion ≥<input type="number" id="mmin" step="0.001" min="0"></label>
 <label>sort<select id="sort"><option value="file">file order</option><option value="dur">duration</option><option value="bright">brightness</option><option value="sat">saturation</option><option value="hue">hue</option><option value="motion">motion</option></select></label>
 <span class="count" id="count"></span></div>
<div class="grid" id="grid"></div>
</main>"""
    data = f"window.FILES={json.dumps(files_light)};window.SHOTS={json.dumps(all_shots)};"
    (out / "index.html").write_text(_page("Footage catalogue", body, INDEX_JS, data), encoding="utf-8")
    return out / "index.html"
