#!/usr/bin/env python3
"""Turn CI build artifacts into versioned release packages plus a manifest.

  package.py build   --artifacts DIR --version V --channel staging --commit SHA --out DIR
  package.py promote --manifest-dir DIR --channel stable

`build` writes, under --out:
  packages/<V>/<component>-<platform>.zip|.tar.gz    installer components
  packages/<V>/standalone/...                         one-folder downloads (app + agent)
  packages/<V>/setup/<channel>/IDR-Setup.exe | idr-setup.sh
  packages/<V>/SHA256SUMS                             every file above
  manifest.json, manifest.tsv                         (signed later by CI)

Paths in the manifest are relative to the channel root (/staging/, /stable/),
so promoting a version only copies packages/<V> and rewrites "channel".
Components and dependencies mirror how the apps find their native pieces:
`idrt` and the Target GUI look for target-agent next to their own exe, `idr`
for idr_c_api and source-agent next to its exe. The installer puts every
component in one folder, so the shared target-agent is installed once.
"""
import argparse
import hashlib
import io
import json
import shutil
import tarfile
import time
import zipfile
from pathlib import Path

PLATFORMS = ['windows-x64', 'linux-x64', 'macos-arm64']

# id, display name, kind, CI artifact prefix, requires, platforms
COMPONENTS = [
    ('target-cli', 'IDR Target CLI', 'app', 'idrt', ['target-agent'], PLATFORMS),
    ('target-gui', 'IDR Target GUI', 'app', 'idr_target_app', ['target-agent'], ['windows-x64']),
    ('source-cli', 'IDR Source CLI', 'app', 'idr', [], PLATFORMS),
    ('target-agent', 'IDR Target agent', 'dependency', 'idrt', [], PLATFORMS),
]
SUMMARIES = {
    'target-cli': '`idrt`: register this machine as a Target, publish services, approve devices.',
    'target-gui': 'Desktop app for the Target: sign in, register, services, transfers.',
    'source-cli': '`idr`: enroll this machine as a Source, connect to Targets, send files.',
    'target-agent': 'Background agent that serves this Target. Shared by the Target CLI and GUI.',
}
# Downloadable on their own (website "individual apps"): everything they need in one folder.
STANDALONE = {'target-cli': 'idrt', 'target-gui': 'idr-target-app', 'source-cli': 'idr'}


def is_agent(rel: str) -> bool:
    return Path(rel).name.startswith('target-agent')


def unix_mode(rel: str) -> int:
    """upload-artifact drops exec bits; restore them for binaries and libs."""
    name = Path(rel).name
    if rel.startswith('config/') or name.endswith(('.json', '.h', '.txt')):
        return 0o644
    return 0o755


def files_of(folder: Path):
    return sorted(p.relative_to(folder).as_posix() for p in folder.rglob('*') if p.is_file())


def write_archive(dest: Path, folder: Path, rels, platform: str):
    """Deterministic archive: .zip on Windows, .tar.gz (keeps modes) elsewhere."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if platform.startswith('windows'):
        with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as z:
            for rel in rels:
                info = zipfile.ZipInfo(rel, (2020, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, (folder / rel).read_bytes())
    else:
        with tarfile.open(dest, 'w:gz', format=tarfile.PAX_FORMAT) as t:
            for rel in rels:
                data = (folder / rel).read_bytes()
                info = tarfile.TarInfo(rel)
                info.size, info.mode, info.mtime = len(data), unix_mode(rel), 1577836800
                t.addfile(info, io.BytesIO(data))


def ext(platform):
    return '.zip' if platform.startswith('windows') else '.tar.gz'


def entry(root: Path, path: Path):
    data = path.read_bytes()
    return {'path': path.relative_to(root).as_posix(),
            'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}


def build(a):
    arts, out = Path(a.artifacts), Path(a.out)
    pkg = out / 'packages' / a.version
    if pkg.exists():
        shutil.rmtree(pkg)
    components, standalone = [], []
    for cid, name, kind, art, requires, plats in COMPONENTS:
        comp = {'id': cid, 'name': name, 'kind': kind, 'requires': requires,
                'summary': SUMMARIES[cid], 'files': {}}
        alone = {'id': cid, 'name': name, 'files': {}}
        for plat in plats:
            src = arts / f'{art}-{plat}'
            if not src.is_dir():
                raise SystemExit(f'missing artifact {src}')
            rels = files_of(src)
            if cid == 'target-agent':
                part = [r for r in rels if is_agent(r)]
            else:
                part = [r for r in rels if not is_agent(r)]
            if not part:
                raise SystemExit(f'{cid} {plat}: no files in {src}')
            dest = pkg / f'{cid}-{plat}{ext(plat)}'
            write_archive(dest, src, part, plat)
            comp['files'][plat] = entry(out, dest)
            if cid in STANDALONE:
                if part == rels:  # nothing split off (idr): the component is the standalone
                    alone['files'][plat] = comp['files'][plat]
                else:
                    sdest = pkg / 'standalone' / f'{STANDALONE[cid]}-{plat}{ext(plat)}'
                    write_archive(sdest, src, rels, plat)
                    alone['files'][plat] = entry(out, sdest)
        components.append(comp)
        if cid in STANDALONE:
            standalone.append(alone)

    # Setup bootstrappers, one per channel (the channel is baked in).
    setup = {}
    script = Path(__file__).parent / 'installer' / 'unix' / 'idr-setup.sh'
    for channel in ('staging', 'stable'):
        d = pkg / 'setup' / channel
        d.mkdir(parents=True)
        exe = arts / 'idr-setup-windows' / f'IDR-Setup-{channel}.exe'
        if not exe.is_file():
            raise SystemExit(f'missing {exe}')
        shutil.copyfile(exe, d / 'IDR-Setup.exe')
        text = script.read_text().replace('IDR_CHANNEL:-staging', f'IDR_CHANNEL:-{channel}')
        (d / 'idr-setup.sh').write_bytes(text.replace('\r\n', '\n').encode())
        sh = entry(out, d / 'idr-setup.sh')
        setup[channel] = {'windows-x64': entry(out, d / 'IDR-Setup.exe'),
                          'linux-x64': sh, 'macos-arm64': sh}

    manifest = {
        'schema': 1, 'channel': a.channel, 'version': a.version, 'commit': a.commit,
        'published': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'components': components, 'standalone': standalone, 'setup': setup,
    }
    with open(pkg / 'SHA256SUMS', 'w', newline='\n') as f:
        for p in sorted(x for x in pkg.rglob('*') if x.is_file() and x.name != 'SHA256SUMS'):
            f.write(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(pkg).as_posix()}\n')
    write_manifests(out, manifest)
    print(json.dumps({'version': a.version, 'files': sum(1 for _ in pkg.rglob('*') if _.is_file())}))


def write_manifests(out: Path, m):
    """manifest.json for the website and Windows setup; manifest.tsv for the
    POSIX setup script (no JSON parser needed). Same data, both get signed."""
    (out / 'manifest.json').write_text(json.dumps(m, indent=2) + '\n', newline='\n')
    lines = [f"version\t{m['version']}", f"channel\t{m['channel']}"]
    for c in m['components']:
        for plat, f in c['files'].items():
            lines.append('\t'.join(['pkg', c['id'], plat, f['path'], f['sha256'], str(f['size']),
                                    ','.join(c['requires']) or '-', c['kind'], c['name']]))
    (out / 'manifest.tsv').write_text('\n'.join(lines) + '\n', newline='\n')


def promote(a):
    d = Path(a.manifest_dir)
    m = json.loads((d / 'manifest.json').read_text())
    m['channel'] = a.channel
    m['published'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    write_manifests(d, m)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build')
    b.add_argument('--artifacts', required=True)
    b.add_argument('--version', required=True)
    b.add_argument('--channel', default='staging', choices=['staging', 'stable'])
    b.add_argument('--commit', default='')
    b.add_argument('--out', required=True)
    p = sub.add_parser('promote')
    p.add_argument('--manifest-dir', required=True)
    p.add_argument('--channel', default='stable', choices=['staging', 'stable'])
    a = ap.parse_args()
    build(a) if a.cmd == 'build' else promote(a)


if __name__ == '__main__':
    main()
