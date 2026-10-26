#!/usr/bin/env python3
"""Verify, publish add-only R1 v3 R2 objects, or build a deterministic ZIP.

Verification/ZIP use only Python's standard library. Upload needs boto3>=1.36;
it uses the existing CLOUDFLARE_API_TOKEN, never creates or stores credentials.
Wrangler 4.103 lacks conditional object PUT, so publication uses boto3's S3
PutObject(IfNoneMatch='*'), which R2 evaluates atomically. No delete/overwrite
operation exists in this tool. Each resumed object is streamed and re-hashed.

References: developers.cloudflare.com/r2/reference/consistency/,
developers.cloudflare.com/r2/api/tokens/, and the boto3 PutObject reference.
"""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile


ACCOUNT = '36f7672020cfc6c515e198c5786d99da'
BUCKET = 'posehub-media'
PREFIX = 'pack/r1-v3/'
VERSION = 'posehub-app-test-pack-r1-v3'
BASE_URL = 'https://media.uuugk.win/pack/r1-v3/'
SOURCE_SHA = 'a1655e5c64055c14af35850b5468390d9d11161e53a87a0cbe7780ec7ed25dc0'
CACHE_CONTROL = 'public,max-age=31536000,immutable'
CHUNK = 1024 * 1024
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


class R2Error(ValueError):
    """Integrity, scope, authentication or add-only publication failed."""


class Conflict(R2Error):
    """An immutable local/remote identity differs from its approved receipt."""


class RequestFailure(R2Error):
    def __init__(self, status=None, retry_after=0):
        self.status = status
        self.retry_after = retry_after
        super().__init__(f'R2 request failed (HTTP {status or "unknown"}); credentials omitted')

    @property
    def retryable(self):
        return self.status is None or self.status in (408, 409, 429, 500, 502, 503, 504)


@dataclass(frozen=True)
class Asset:
    path: str
    local: Path
    size: int
    sha256: str
    content_type: str


def hash_stream(source):
    sha, md5, size = hashlib.sha256(), hashlib.md5(), 0
    while block := source.read(CHUNK):
        sha.update(block)
        md5.update(block)
        size += len(block)
    return size, sha.hexdigest(), base64.b64encode(md5.digest()).decode('ascii')


def receipt(asset):
    with asset.local.open('rb') as source:
        size, sha, md5 = hash_stream(source)
    if (size, sha) != (asset.size, asset.sha256):
        raise Conflict(f'Local receipt mismatch: {asset.path}')
    return md5


def relative_path(value):
    if (not isinstance(value, str) or not value
            or any(c in value for c in '\\:%?#\x00')
            or any(ord(c) < 32 for c in value)
            or any(p in ('', '.', '..') or p.endswith((' ', '.')) for p in value.split('/'))
            or PurePosixPath(value).is_absolute()):
        raise R2Error('Unsafe relative media path')
    reserved = {'CON', 'PRN', 'AUX', 'NUL'} | {
        f'{p}{n}' for p in ('COM', 'LPT') for n in range(1, 10)}
    if any(p.split('.')[0].upper() in reserved for p in value.split('/')):
        raise R2Error('Ambiguous Windows media path')
    return value


def inside(root, relative):
    relative_path(relative)
    target = (root / relative).resolve()
    if not target.is_relative_to(root.resolve()):
        raise R2Error('Media path escapes root')
    return target


def outside_git(path):
    resolved = path.resolve()
    if any((p / '.git').exists() for p in (resolved.parent, *resolved.parents)):
        raise R2Error('Receipts and backup ZIPs must be outside Git')


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise R2Error('Duplicate JSON key')
        result[key] = value
    return result


def scope(account, bucket, prefix):
    if (account, bucket, prefix) != (ACCOUNT, BUCKET, PREFIX):
        raise R2Error('Only the approved account, posehub-media bucket and pack/r1-v3/ prefix are allowed')


def load_assets(root, catalog_sha256):
    if not re.fullmatch('[0-9a-f]{64}', catalog_sha256):
        raise R2Error('An explicit lowercase catalog SHA-256 is required')
    root = root.resolve()
    catalog_path = inside(root, 'catalog.json')
    blob = catalog_path.read_bytes()
    if hashlib.sha256(blob).hexdigest() != catalog_sha256:
        raise Conflict('Catalog SHA-256 differs from the approved value')
    catalog = json.loads(blob, object_pairs_hook=no_duplicates)
    dist = catalog.get('mediaDistribution', {})
    required = {'version': VERSION, 'kind': 'r2-objects@1', 'baseUrl': BASE_URL,
                'pathRule': 'relative-path', 'objectKeyPrefix': PREFIX,
                'sourceCatalogSha256': SOURCE_SHA, 'mediaFiles': 657}
    if (catalog.get('id') != 'app-test-pack-r1'
            or any(dist.get(k) != v for k, v in required.items())):
        raise R2Error('Catalog v3 R2 version manifest differs')
    actions = catalog.get('actions', [])
    ids = [a.get('id') for a in actions]
    complete = [a.get('trainingDefinitionComplete') for a in actions]
    if (len(ids) != 219 or any(not isinstance(i, str) or not i for i in ids)
            or len(set(ids)) != 219 or any(type(c) is not bool for c in complete)
            or sum(complete) != 211):
        raise R2Error('Catalog must retain 219 actions, 211 complete and 8 pending')
    assets = []
    for action in actions:
        files = action.get('files', {})
        if set(files) != {'video', 'cover', 'thumbnail'}:
            raise R2Error('Each action must have exactly video, cover and thumbnail')
        for role, row in files.items():
            path = relative_path(row.get('path'))
            suffix = '.mp4' if role == 'video' else '.webp'
            size, sha = row.get('bytes'), row.get('sha256')
            if (not path.startswith('media/') or not path.endswith(suffix)
                    or type(size) is not int or size <= 0
                    or not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha)
                    or row.get('downloadUrl') != BASE_URL + path
                    or row.get('assetName') != PurePosixPath(path).name):
                raise R2Error('Invalid media receipt or download URL')
            assets.append(Asset(path, inside(root, path), size, sha,
                                'video/mp4' if role == 'video' else 'image/webp'))
    if len({a.path.casefold() for a in assets}) != 657:
        raise R2Error('Media paths must be unique')
    if dist.get('mediaBytes') != sum(a.size for a in assets):
        raise R2Error('Version manifest media byte count differs')
    assets.sort(key=lambda a: a.path)
    assets.append(Asset('catalog.json', catalog_path, len(blob), catalog_sha256, 'application/json'))
    for asset in assets:
        receipt(asset)
    return assets


def summary(assets):
    return {'version': VERSION, 'objects': len(assets), 'mediaFiles': len(assets) - 1,
            'mediaBytes': sum(a.size for a in assets if a.path != 'catalog.json'),
            'catalogSha256': assets[-1].sha256, 'semanticComplete': 211, 'semanticPending': 8}


class Journal:
    """Atomic receipts plus an OS lock; a crash releases the lock automatically."""
    def __init__(self, path, binding):
        outside_git(path)
        self.path, self.binding, self.mutex = path, binding, threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = path.with_suffix(path.suffix + '.lock').open('a+b')
        try:
            if os.fstat(self.lock.fileno()).st_size == 0:
                self.lock.write(b'\0')
                self.lock.flush()
            self.lock.seek(0)
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(self.lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.data = json.loads(path.read_text('utf-8')) if path.exists() else {
                'format': 'posehub-r2-receipts@1', 'binding': binding, 'attempts': [], 'verified': {}}
            if (self.data.get('format') != 'posehub-r2-receipts@1'
                    or self.data.get('binding') != binding):
                raise Conflict('Receipt journal belongs to a different immutable manifest')
        except BaseException:
            self.lock.close()
            raise

    def close(self):
        self.lock.close()

    def record(self, kind, asset, status=None):
        with self.mutex:
            row = {'path': asset.path, 'bytes': asset.size, 'sha256': asset.sha256,
                   'time': time.time()}
            if kind == 'attempt':
                self.data['attempts'].append(row)
            else:
                self.data['verified'][asset.path] = {**row, 'status': status}
            handle, temp = tempfile.mkstemp(prefix='.r2-receipts-', dir=self.path.parent)
            try:
                with os.fdopen(handle, 'w', encoding='utf-8', newline='\n') as stream:
                    json.dump(self.data, stream, sort_keys=True, indent=2)
                    stream.write('\n')
                    stream.flush()
                    os.fsync(stream.fileno())
                deadline, delay = time.monotonic() + 2, .025
                while True:
                    try:
                        os.replace(temp, self.path)
                        break
                    except PermissionError:
                        left = deadline - time.monotonic()
                        if left <= 0:
                            raise
                        time.sleep(min(left, delay))
                        delay = min(.8, delay * 2)
            finally:
                if os.path.exists(temp):
                    os.unlink(temp)


def failure(error):
    response = getattr(error, 'response', {})
    status = response.get('ResponseMetadata', {}).get('HTTPStatusCode')
    headers = response.get('ResponseMetadata', {}).get('HTTPHeaders', {})
    retry = headers.get('retry-after', '0')
    return RequestFailure(status, min(300, float(retry)) if str(retry).isdigit() else 0)


class S3Transport:
    def __init__(self, client, bucket=BUCKET, prefix=PREFIX):
        self.client, self.bucket, self.prefix = client, bucket, prefix

    def verify(self, asset):
        try:
            result = self.client.get_object(Bucket=self.bucket, Key=self.prefix + asset.path)
        except Exception as error:
            failed = failure(error)
            if failed.status == 404:
                return False
            raise failed from None
        body = result['Body']
        try:
            if result.get('ContentLength', asset.size) != asset.size:
                raise Conflict(f'Remote size differs: {asset.path}')
            for field, expected in (('ContentType', asset.content_type), ('CacheControl', CACHE_CONTROL)):
                if field in result and result[field].replace(' ', '') != expected:
                    raise Conflict(f'Remote {field} differs: {asset.path}')
            metadata_sha = result.get('Metadata', {}).get('sha256')
            if metadata_sha is not None and metadata_sha != asset.sha256:
                raise Conflict(f'Remote SHA-256 metadata differs: {asset.path}')
            try:
                size, sha, _ = hash_stream(body)
            except Exception:
                raise RequestFailure() from None
            if (size, sha) != (asset.size, asset.sha256):
                raise Conflict(f'Remote bytes/SHA-256 differ: {asset.path}')
        finally:
            body.close()
        return True

    def create(self, asset):
        with asset.local.open('rb') as source:
            size, sha, md5 = hash_stream(source)
            if (size, sha) != (asset.size, asset.sha256):
                raise Conflict(f'Local receipt changed: {asset.path}')
            source.seek(0)
            try:
                self.client.put_object(Bucket=self.bucket, Key=self.prefix + asset.path,
                    Body=source, ContentLength=asset.size, ContentMD5=md5,
                    ContentType=asset.content_type, CacheControl=CACHE_CONTROL,
                    Metadata={'sha256': asset.sha256}, IfNoneMatch='*')
            except Exception as error:
                raise failure(error) from None


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise R2Error('Unexpected authentication API redirect refused')


def make_transport(account, bucket, prefix, workers):
    scope(account, bucket, prefix)
    try:
        import boto3
        from botocore.config import Config
    except ImportError:
        raise R2Error('Upload requires boto3>=1.36 (install into an isolated Python dependency directory)') from None
    token = os.environ.get('CLOUDFLARE_API_TOKEN')
    if not token:
        raise R2Error('CLOUDFLARE_API_TOKEN is required; credential values are never logged')
    request = Request('https://api.cloudflare.com/client/v4/user/tokens/verify',
                      headers={'Authorization': 'Bearer ' + token})
    try:
        with build_opener(NoRedirect()).open(request, timeout=30) as response:
            data = json.loads(response.read(1024 * 1024))
    except (HTTPError, URLError, OSError):
        raise R2Error('Cloudflare token verification failed; credential/error body omitted') from None
    identity = data.get('result', {})
    if (data.get('success') is not True or identity.get('status') != 'active'
            or not re.fullmatch('[a-f0-9]{32}', identity.get('id', ''))):
        raise R2Error('An active API token identity is required')
    # Official R2 token mapping; no new token, credential file or custom signing.
    client = boto3.client('s3', endpoint_url=f'https://{account}.r2.cloudflarestorage.com',
        aws_access_key_id=identity['id'], aws_secret_access_key=hashlib.sha256(token.encode()).hexdigest(),
        region_name='auto', config=Config(signature_version='s3v4', max_pool_connections=workers,
            connect_timeout=30, read_timeout=120, retries={'total_max_attempts': 1},
            request_checksum_calculation='when_required', response_checksum_validation='when_required',
            s3={'addressing_style': 'path'}))
    if 'IfNoneMatch' not in client.meta.service_model.operation_model('PutObject').input_shape.members:
        raise R2Error('Installed boto3 lacks atomic IfNoneMatch support; upgrade it')
    return S3Transport(client, bucket, prefix)


def upload_one(transport, journal, asset, sleep=time.sleep):
    created = False
    for attempt in range(6):
        try:
            if transport.verify(asset):
                status = 'uploaded' if created else 'identical'
                journal.record('verified', asset, status)
                return status
            journal.record('attempt', asset)
            try:
                transport.create(asset)
                created = True
            except RequestFailure as failed:
                # A lost response may have committed. All retries remain conditional.
                if failed.status != 412 and not failed.retryable:
                    raise
                if transport.verify(asset):
                    journal.record('verified', asset, 'reconciled')
                    return 'reconciled'
                if failed.status == 412:
                    raise Conflict(f'Conditional write rejected but object is absent: {asset.path}')
                raise failed
            if transport.verify(asset):
                journal.record('verified', asset, 'uploaded')
                return 'uploaded'
            raise RequestFailure()
        except RequestFailure as failed:
            if not failed.retryable or attempt == 5:
                raise
            sleep(max(failed.retry_after, min(30, 2 ** attempt)))
    raise R2Error('Unreachable upload state')


def publish(assets, transport, journal, workers=4, limit=None):
    if workers not in (1, 2, 3, 4) or (limit is not None and not 1 <= limit < len(assets)):
        raise R2Error('Use 1..4 workers and an optional media-only smoke limit')
    media = [a for a in assets if a.path != 'catalog.json']
    selected = media[:limit] if limit is not None else media
    stopped, results = threading.Event(), {}

    def work(asset):
        if stopped.is_set():
            return None
        try:
            return upload_one(transport, journal, asset)
        except BaseException:
            stopped.set()
            raise

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(work, a): a for a in selected}
        for future in as_completed(futures):
            asset, status = futures[future], future.result()
            if status is not None:
                results[asset.path] = status
                print(json.dumps({'verified': len(results), 'total': len(selected),
                                  'path': asset.path, 'status': status}), flush=True)
    if limit is None:
        catalog = next(a for a in assets if a.path == 'catalog.json')
        results[catalog.path] = upload_one(transport, journal, catalog)
        if len(results) != 658:
            raise R2Error('Publication incomplete: all 658 objects must be verified')
    return results


def backup_zip(assets, output):
    outside_git(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix='.posehub-zip-', dir=output.parent)
    os.close(handle)
    temporary = Path(temporary)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
            for asset in sorted(assets, key=lambda a: a.path):
                info = zipfile.ZipInfo(asset.path, FIXED_TIME)
                info.create_system, info.external_attr = 0, 0o100644 << 16
                with asset.local.open('rb') as source, archive.open(info, 'w') as target:
                    sha, size = hashlib.sha256(), 0
                    while block := source.read(CHUNK):
                        target.write(block)
                        sha.update(block)
                        size += len(block)
                    if (size, sha.hexdigest()) != (asset.size, asset.sha256):
                        raise Conflict(f'Local bytes changed while building backup: {asset.path}')
        with temporary.open('rb') as stream:
            size, sha, _ = hash_stream(stream)
        try:
            os.link(temporary, output)  # Atomic no-replace publication, including Windows NTFS.
        except FileExistsError:
            with output.open('rb') as stream:
                old_size, old_sha, _ = hash_stream(stream)
            if (old_size, old_sha) != (size, sha):
                raise Conflict('Existing backup ZIP differs; it was left untouched')
        return {'path': str(output.resolve()), 'bytes': size, 'sha256': sha, 'entries': len(assets)}
    finally:
        temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('verify', 'upload', 'zip'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--catalog-sha256', required=True)
    parser.add_argument('--account', default=ACCOUNT)
    parser.add_argument('--bucket', default=BUCKET)
    parser.add_argument('--prefix', default=PREFIX)
    parser.add_argument('--journal', type=Path, help='Persistent receipts outside every Git checkout')
    parser.add_argument('--workers', type=int, choices=(1, 2, 3, 4), default=4)
    parser.add_argument('--limit', type=int, help='Smoke test only the first N media; never publish catalog')
    parser.add_argument('--output', type=Path, help='Deterministic ZIP destination outside Git')
    args = parser.parse_args(argv)
    try:
        scope(args.account, args.bucket, args.prefix)
        assets = load_assets(args.root, args.catalog_sha256)
        result = summary(assets)
        if args.command == 'zip':
            if args.output is None:
                raise R2Error('zip requires --output')
            result['backup'] = backup_zip(assets, args.output)
        elif args.command == 'upload':
            if args.journal is None:
                raise R2Error('upload requires --journal outside Git')
            binding = {**result, 'account': args.account, 'bucket': args.bucket, 'prefix': args.prefix}
            journal = Journal(args.journal, binding)
            try:
                transport = make_transport(args.account, args.bucket, args.prefix, args.workers)
                result['verifiedObjects'] = len(publish(assets, transport, journal, args.workers, args.limit))
                result['complete'] = args.limit is None
            finally:
                journal.close()
        print(json.dumps(result, sort_keys=True), flush=True)
        return 0
    except (R2Error, OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f'error: {error}', file=sys.stderr, flush=True)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
