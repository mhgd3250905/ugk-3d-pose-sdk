#!/usr/bin/env python3
"""Re-encode the R1 v2 media without modifying its source or action semantics.

Requires FFmpeg/ffprobe and Pillow. Uses the existing packed RGB-over-alpha
layout, software x264, bounded workers, receipts and no-overwrite publication.
The output is outside Git. R2 publication uses a separate receipt-checked tool.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import struct
import subprocess
import tempfile
import time

from PIL import Image

SOURCE_SHA = 'a1655e5c64055c14af35850b5468390d9d11161e53a87a0cbe7780ec7ed25dc0'
TAG = 'posehub-app-test-pack-r1-v3'
REPO = 'mhgd3250905/ugk-3d-pose-sdk'
BASE_URL = 'https://media.uuugk.win/pack/r1-v3/'
SAMPLE_IDS = ('abs-A', 'chest-B', 'h-lateral-step-lunge', 'forearms-C', 'h-towel-isometric-curl')
CHUNK = 1024 * 1024


class MediaError(ValueError):
    pass


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as source:
        while block := source.read(CHUNK):
            result.update(block)
    return result.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        with os.fdopen(handle, 'wb') as target:
            target.write((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
        for attempt in range(81):
            try:
                os.replace(temporary, path)
                break
            except PermissionError:
                if attempt == 80:
                    raise
                time.sleep(.025)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def inside(root: Path, relative: str) -> Path:
    parsed = PurePosixPath(relative)
    if (not relative or parsed.is_absolute() or '\\' in relative
            or any(c in relative for c in ':?#%')
            or any(p in ('', '.', '..') or p.startswith('.') for p in relative.split('/'))):
        raise MediaError('Unsafe pack path')
    target = (root / relative).resolve()
    if not target.is_relative_to(root.resolve()):
        raise MediaError(f'Pack path escapes root: {relative}; resolved={target}; root={root.resolve()}')
    return target


def source_catalog(root: Path) -> dict:
    blob = (root / 'catalog.json').read_bytes()
    if hashlib.sha256(blob).hexdigest() != SOURCE_SHA:
        raise MediaError('Source must be the exact approved v2 catalogue')
    catalog = json.loads(blob)
    actions = catalog['actions']
    if (len(actions) != 219 or len({a['id'] for a in actions}) != 219
            or sum(a['trainingDefinitionComplete'] for a in actions) != 211):
        raise MediaError('Source 219/211/8 identity mismatch')
    names = [PurePosixPath(f['path']).name for a in actions for f in a['files'].values()]
    if len(names) != 657 or len({n.casefold() for n in names}) != 657:
        raise MediaError('Release asset basenames are not unique')
    return catalog


def probe(path: Path, count_frames: bool = False) -> dict:
    command = ['ffprobe', '-v', 'error']
    if count_frames:
        command += ['-count_frames']
    command += ['-show_streams', '-show_format', '-of', 'json', str(path)]
    result = subprocess.run(command, capture_output=True, check=True)
    data = json.loads(result.stdout)
    videos = [s for s in data['streams'] if s['codec_type'] == 'video']
    if len(videos) != 1:
        raise MediaError('Expected one video stream')
    return {**videos[0], 'audioStreams': sum(s['codec_type'] == 'audio' for s in data['streams'])}


def faststart(path: Path) -> bool:
    atoms = []
    length = path.stat().st_size
    with path.open('rb') as stream:
        while stream.tell() + 8 <= length:
            start = stream.tell()
            size, kind = struct.unpack('>I4s', stream.read(8))
            if size == 1:
                size = struct.unpack('>Q', stream.read(8))[0]
            elif size == 0:
                size = length - start
            if size < 8 or start + size > length:
                raise MediaError('Invalid MP4 atom size')
            atoms.append(kind)
            stream.seek(start + size)
    return b'moov' in atoms and b'mdat' in atoms and atoms.index(b'moov') < atoms.index(b'mdat')


def validate_video(source: dict, target: dict, path: Path) -> None:
    if (target['codec_name'] != 'h264' or target['profile'] != 'High'
            or target['pix_fmt'] != 'yuv420p' or target['codec_tag_string'] != 'avc1'
            or target['audioStreams'] != 0 or target['height'] != target['width'] * 2
            or min(target['width'], target['height']) > 720
            or Fraction(source['avg_frame_rate']) != Fraction(target['avg_frame_rate'])
            or Fraction(source['r_frame_rate']) != Fraction(target['r_frame_rate'])
            or int(source['nb_frames']) != int(target['nb_frames'])
            or abs(float(source['duration']) - float(target['duration'])) > .00001
            or not faststart(path)):
        raise MediaError('Re-encoded video violates codec/frame/layout/faststart contract')
    if 'nb_read_frames' in target and int(target['nb_read_frames']) != int(source['nb_frames']):
        raise MediaError('Decoded frame count differs from source')


def encode_file(source_root: Path, output_root: Path, action_id: str,
                role: str, original: dict, recipe: dict, count_frames: bool = False) -> dict:
    relative = original['path']
    source = inside(source_root, relative)
    target = inside(output_root, relative)
    receipt_path = output_root / '.receipts' / (hashlib.sha256(relative.encode()).hexdigest() + '.json')
    if source.stat().st_size != original['bytes'] or digest(source) != original['sha256']:
        raise MediaError(f'Source media integrity mismatch: {action_id}/{role}')
    if target.exists():
        if not receipt_path.is_file():
            raise MediaError(f'Existing output lacks its receipt: {relative}')
        receipt = json.loads(receipt_path.read_bytes())
        if (receipt['sourceSha256'] != original['sha256'] or receipt['recipe'] != recipe
                or receipt['bytes'] != target.stat().st_size or receipt['sha256'] != digest(target)):
            raise MediaError(f'Output or encoding recipe changed: {relative}')
        if role == 'video':
            actual = probe(target, count_frames)
            validate_video(probe(source), actual, target)
            details = {key: actual[key] for key in ('width', 'height', 'profile', 'level',
                       'pix_fmt', 'avg_frame_rate', 'r_frame_rate', 'duration', 'nb_frames')}
            details.update(faststart=True, audioStreams=0)
        else:
            with Image.open(target) as image:
                image.load()
                maximum = recipe['coverMax'] if role == 'cover' else recipe['thumbnailMax']
                if image.format != 'WEBP' or max(image.size) > maximum:
                    raise MediaError('Resumed image format or size changed')
                details = {'width': image.width, 'height': image.height,
                           'hasAlpha': 'A' in image.getbands()}
        if receipt['details'] != details:
            raise MediaError(f'Output receipt details changed: {relative}')
        return receipt
    target.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(suffix=target.suffix, dir=target.parent)
    os.close(handle)
    temporary = Path(temporary)
    try:
        if role == 'video':
            before = probe(source)
            if before['height'] != before['width'] * 2:
                raise MediaError('Input is not RGB-over-alpha 2h packing')
            width = min(720, before['width']) // 2 * 2
            command = ['ffmpeg', '-hide_banner', '-v', 'error', '-nostdin', '-y',
                       '-threads', '2', '-filter_threads', '1', '-i', str(source),
                       '-map', '0:v:0', '-an', '-sn', '-dn', '-map_metadata', '-1', '-map_chapters', '-1']
            if width != before['width']:
                command += ['-vf', f'scale={width}:{width * 2}:flags=lanczos']
            command += ['-c:v', 'libx264', '-preset', recipe['preset'], '-crf', str(recipe['crf']),
                        '-profile:v', 'high', '-pix_fmt', 'yuv420p', '-threads', '2',
                        '-tag:v', 'avc1', '-color_range', 'tv', '-colorspace', 'bt709',
                        '-color_primaries', 'bt709', '-color_trc', 'bt709',
                        '-fps_mode', 'passthrough', '-movflags', '+faststart', str(temporary)]
            result = subprocess.run(command, capture_output=True)
            if result.returncode:
                raise MediaError(f'FFmpeg failed for {action_id}: {result.stderr.decode(errors="replace")[-1000:]}')
            after = probe(temporary, count_frames)
            validate_video(before, after, temporary)
            details = {key: after[key] for key in ('width', 'height', 'profile', 'level',
                       'pix_fmt', 'avg_frame_rate', 'r_frame_rate', 'duration', 'nb_frames')}
            details.update(faststart=True, audioStreams=0)
        else:
            maximum = recipe['coverMax'] if role == 'cover' else recipe['thumbnailMax']
            with Image.open(source) as loaded:
                image = loaded.convert('RGBA')
                image.thumbnail((maximum, maximum), Image.Resampling.LANCZOS)
                image.save(temporary, 'WEBP', quality=80, alpha_quality=100, method=6)
            with Image.open(temporary) as decoded:
                decoded.load()
                if decoded.format != 'WEBP' or max(decoded.size) > maximum:
                    raise MediaError('Output image has wrong format or display size')
                details = {'width': decoded.width, 'height': decoded.height,
                           'hasAlpha': 'A' in decoded.getbands()}
        # A hard link makes the completed output visible atomically, without
        # overwriting any existing output or touching its source.
        os.link(temporary, target)
        receipt = {'actionId': action_id, 'role': role, 'path': relative,
                   'sourceSha256': original['sha256'], 'sourceBytes': original['bytes'],
                   'bytes': target.stat().st_size, 'sha256': digest(target),
                   'recipe': recipe, 'details': details}
        write_json(receipt_path, receipt)
        return receipt
    finally:
        temporary.unlink(missing_ok=True)


def run(args) -> None:
    source = args.source.resolve()
    output = args.output.resolve()
    if source == output or output.is_relative_to(source) or source.is_relative_to(output):
        raise MediaError('Source and output must be separate non-nested directories')
    catalog = source_catalog(source)
    output.mkdir(parents=True, exist_ok=True)
    recipe = {'crf': args.crf, 'preset': 'slow', 'videoShortMax': 720,
              'coverMax': 640, 'thumbnailMax': 192, 'webpQuality': 80,
              'encoderThreads': 2, 'packing': 'rgb-top-red-alpha-bottom'}
    selected = set(args.ids.split(',')) if args.ids else None
    rows = [(a['id'], role, file) for a in catalog['actions']
            if selected is None or a['id'] in selected for role, file in a['files'].items()
            if not args.videos_only or role == 'video']
    if selected and {i for i, _, _ in rows} != selected:
        raise MediaError('Unknown requested action ID')
    receipts = {}
    plan_rows = [{'name': PurePosixPath(f['path']).name, 'path': str(inside(output, f['path'])),
                  'bytes': None, 'sha256': None}
                 for a in catalog['actions'] for f in a['files'].values()]
    plan_rows.append({'name': 'catalog.json', 'path': str(output / 'catalog.json'), 'bytes': None, 'sha256': None})
    plan = {'repo': REPO, 'tag': TAG, 'assets': plan_rows}
    by_path = {row['path']: row for row in plan_rows}
    if args.plan and args.plan.exists():
        previous = json.loads(args.plan.read_bytes())
        identity = lambda data: (data['repo'], data['tag'],
            [(row['name'], row['path']) for row in data['assets']])
        if identity(previous) != identity(plan):
            raise MediaError('Existing upload-plan identities differ')
        for old, current in zip(previous['assets'], plan_rows):
            if old['bytes'] is not None or old['sha256'] is not None:
                path = Path(current['path'])
                if (not path.is_file() or path.stat().st_size != old['bytes']
                        or digest(path) != old['sha256']):
                    raise MediaError('Previously ready upload receipt differs')
                current.update(bytes=old['bytes'], sha256=old['sha256'])
    if args.plan:
        write_json(args.plan, plan)
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.workers) as workers:
        futures = [workers.submit(encode_file, source, output, i, k, f, recipe, args.decode_check)
                   for i, k, f in rows]
        for future in as_completed(futures):
            receipt = future.result()
            receipts[receipt['path']] = receipt
            row = by_path[str(inside(output, receipt['path']))]
            row.update(bytes=receipt['bytes'], sha256=receipt['sha256'])
            if args.plan:
                write_json(args.plan, plan)
            if len(receipts) % 5 == 0 or len(receipts) == len(rows):
                print(json.dumps({'completed': len(receipts), 'total': len(rows),
                    'outputBytes': sum(r['bytes'] for r in receipts.values()),
                    'sourceBytes': sum(r['sourceBytes'] for r in receipts.values()),
                    'elapsedSeconds': round(time.monotonic() - started)}), flush=True)
    summary = {'recipe': recipe, 'sourceCatalogSha256': SOURCE_SHA, 'files': list(receipts.values()),
               'mediaBytes': sum(r['bytes'] for r in receipts.values()),
               'sourceBytes': sum(r['sourceBytes'] for r in receipts.values())}
    write_json(output / 'compression-receipts.json', summary)
    if selected or args.videos_only:
        return
    for action in catalog['actions']:
        for role, file in action['files'].items():
            receipt = receipts[file['path']]
            file.update(bytes=receipt['bytes'], sha256=receipt['sha256'],
                        width=receipt['details']['width'], height=receipt['details']['height'],
                        assetName=PurePosixPath(file['path']).name,
                        downloadUrl=BASE_URL + file['path'])
    catalog['mediaDistribution'] = {'version': TAG, 'kind': 'r2-objects@1',
        'baseUrl': BASE_URL, 'pathRule': 'relative-path', 'objectKeyPrefix': 'pack/r1-v3/',
        'sourceCatalogSha256': SOURCE_SHA,
        'mediaFiles': 657, 'mediaBytes': summary['mediaBytes'], 'recipe': recipe}
    write_json(output / 'catalog.json', catalog)
    by_path[str(output / 'catalog.json')].update(bytes=(output / 'catalog.json').stat().st_size,
                                               sha256=digest(output / 'catalog.json'))
    if args.plan:
        write_json(args.plan, plan)
    print(json.dumps({'catalogSha256': digest(output / 'catalog.json'),
        'catalogBytes': (output / 'catalog.json').stat().st_size, 'mediaBytes': summary['mediaBytes'],
        'averageActionBytes': summary['mediaBytes'] / 219, 'files': len(receipts)}), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--crf', type=int, choices=(26, 27, 28), default=27)
    parser.add_argument('--workers', type=int, choices=(1, 2), default=2)
    parser.add_argument('--ids', help='Comma-separated pilot IDs; does not write a release catalogue')
    parser.add_argument('--videos-only', action='store_true')
    parser.add_argument('--decode-check', action='store_true', help='Count all decoded video frames after encode')
    parser.add_argument('--plan', type=Path, help='Atomic pending-to-ready release upload plan')
    args = parser.parse_args()
    try:
        run(args)
        return 0
    except (MediaError, OSError, subprocess.CalledProcessError) as error:
        print(f'error: {error}', flush=True)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
