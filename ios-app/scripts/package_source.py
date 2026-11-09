#!/usr/bin/env python3
"""Package only source/docs/fixtures, never workspace credentials or caches."""
import hashlib, json, pathlib, sys, zipfile
root = pathlib.Path(__file__).resolve().parents[1]
out = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root.parent / 'PhoneAgent-iOS-source.zip'
exclude = {'.git', '.build', 'DerivedData', '__pycache__', 'xcuserdata', '.venv'}
files = [p for p in sorted(root.rglob('*')) if p.is_file() and not any(x in exclude for x in p.relative_to(root).parts)]
manifest = root / 'SOURCE_MANIFEST.json'
manifest.write_text(json.dumps({'status': 'source-candidate-uncompiled', 'source_date': '2026-10-02', 'files': [{'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in files if p != manifest]}, indent=2) + '\n')
if manifest not in files: files.append(manifest); files.sort()
for p in files:
    assert p.suffix not in {'.pem', '.key', '.p12', '.pyc', '.env'}, f'Forbidden file: {p}'
assert out not in files, 'Output must be outside source directory'
out.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for p in files:
        info=zipfile.ZipInfo('ios-agent-app/'+p.relative_to(root).as_posix(), date_time=(2026,10,2,0,0,0))
        info.compress_type=zipfile.ZIP_DEFLATED
        z.writestr(info,p.read_bytes())
with zipfile.ZipFile(out) as z: assert z.testzip() is None
print(f'{len(files)} files; {out.stat().st_size} bytes; SHA256 {hashlib.sha256(out.read_bytes()).hexdigest()}')
