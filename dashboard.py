#!/usr/bin/env python3
"""Local-only Raspberry Pi webcam dashboard with replay and motion clips."""
from flask import Flask, Response, abort, render_template_string, send_from_directory
from pathlib import Path
import os
import subprocess
import tempfile
import urllib.request

app = Flask(__name__)
EVENTS = Path(os.environ.get('PETCAM_EVENTS', str(Path.home() / 'petcam-data/events')))
RING = Path('/run/petcam/replay')
LIVE = 'http://127.0.0.1:8080/stream'
PAGE = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pet Cam</title><style>
body{background:#101722;color:#f1f5f9;font:16px system-ui,sans-serif;max-width:850px;margin:auto;padding:16px}h1{margin:0 0 12px}img{width:100%;background:#333;border-radius:12px;aspect-ratio:16/9;object-fit:contain}a{color:#c3e1ff}button,.btn{background:#254966;color:white;border:1px solid #507fa1;border-radius:9px;padding:10px 14px;display:inline-block;text-decoration:none;margin:5px 6px 5px 0;font:inherit}.event{padding:9px 0;border-bottom:1px solid #394356}small{color:#94a3b8}</style></head><body><h1>📷 Pet Cam</h1><img src="/live" alt="Live webcam"><p><small>Live camera · private local connection</small></p><h2>Instant replay</h2><a class="btn" href="/replay/30" target="_blank">Last 30 seconds</a><a class="btn" href="/replay/60" target="_blank">Last 60 seconds</a><small>Ends about 2–4 seconds before you tap.</small><h2>Recent motion clips</h2><div id="events">Loading…</div><script>
async function refresh(){try{const r=await fetch('/api/events',{cache:'no-store'});const xs=await r.json();const e=document.getElementById('events');e.replaceChildren();if(!xs.length){e.textContent='No motion clips yet.';return;}for(const x of xs){const d=document.createElement('div');d.className='event';const a=document.createElement('a');a.href='/event/'+encodeURIComponent(x.name);a.textContent=x.label; a.target='_blank';d.append(a);e.append(d);}}catch(e){document.getElementById('events').textContent='Could not load clips.'}}
refresh();setInterval(refresh,20000);</script></body></html>'''

@app.after_request
def no_cache(resp):
    resp.headers['Cache-Control'] = 'no-store'
    resp.headers['X-Content-Type-Options'] = 'nosniff'
    resp.headers['X-Frame-Options'] = 'DENY'
    return resp

@app.get('/')
def home():
    return PAGE

@app.get('/live')
def live():
    try:
        upstream = urllib.request.urlopen(LIVE, timeout=15)
    except (OSError, TimeoutError):
        return 'Camera stream unavailable', 503
    content_type = upstream.headers.get('Content-Type', 'multipart/x-mixed-replace')
    def frames():
        try:
            while True:
                block = upstream.read(16384)
                if not block:
                    break
                yield block
        finally:
            upstream.close()
    return Response(frames(), content_type=content_type)

@app.get('/api/events')
def list_events():
    from flask import jsonify
    files = sorted(EVENTS.glob('*.mp4'), key=lambda p: p.stat().st_mtime, reverse=True)
    # Skip files Motion may still be writing (fresh files); click after the event finishes.
    import time
    files = [p for p in files if time.time() - p.stat().st_mtime > 10]
    return jsonify([{'name':p.name,'label':p.stem.replace('-',' · ')} for p in files[:40]])

@app.get('/event/<path:name>')
def event(name):
    if '/' in name or not name.endswith('.mp4'):
        abort(404)
    return send_from_directory(EVENTS, name, mimetype='video/mp4', as_attachment=False)

@app.get('/replay/<int:seconds>')
def replay(seconds):
    if seconds not in (30, 60):
        abort(404)
    files = sorted(RING.glob('seg*.mp4'), key=lambda p: p.stat().st_mtime)
    if len(files) < 4:
        return 'Replay buffer is warming up. Try again after 10 seconds.', 503
    # Newest segment is being written; leave it out.
    files = files[:-1][-(seconds // 2):]
    with tempfile.TemporaryDirectory(prefix='pet-replay-') as d:
        manifest = Path(d) / 'list.txt'
        manifest.write_text(''.join("file '" + str(p) + "'\n" for p in files))
        out = Path(d) / 'replay.mp4'
        p = subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-nostdin','-y',
             '-f','concat','-safe','0','-i',str(manifest),'-c','copy',
             '-movflags','+faststart',str(out)], capture_output=True, timeout=25)
        if p.returncode or not out.exists():
            app.logger.error('Replay failure: %s', p.stderr.decode(errors='replace'))
            return 'Replay temporarily unavailable; check journalctl -u petcam-dashboard.', 503
        data = out.read_bytes()
    return Response(data, mimetype='video/mp4', headers={'Content-Disposition':'inline; filename="pet-replay.mp4"'})

if __name__ == '__main__':
    from waitress import serve
    serve(app, host='127.0.0.1', port=8090, threads=6, channel_timeout=120)
