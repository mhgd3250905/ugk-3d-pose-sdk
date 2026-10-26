"""Integrity/add-only regressions without live credentials or network access."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / 'posehub_r2_assets.py'
SPEC = importlib.util.spec_from_file_location('posehub_r2_assets', SCRIPT)
r2 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = r2
SPEC.loader.exec_module(r2)


class HttpError(Exception):
    def __init__(self, status):
        self.response = {'ResponseMetadata': {'HTTPStatusCode': status}}


class FakeS3:
    """Small service boundary: stored bytes, conditional writes and lost replies."""
    def __init__(self):
        self.objects, self.puts, self.fail = {}, [], None
        self.bodies = []

    def get_object(self, **kwargs):
        key = kwargs['Key']
        if key not in self.objects:
            raise HttpError(404)
        row = self.objects[key]
        body = io.BytesIO(row['data'])
        self.bodies.append(body)
        return {k: v for k, v in row.items() if k != 'data'} | {'Body': body}

    def put_object(self, **kwargs):
        self.puts.append({k: v for k, v in kwargs.items() if k != 'Body'})
        key = kwargs['Key']
        if kwargs['IfNoneMatch'] != '*':
            raise AssertionError('Unsafe unconditional write')
        if key in self.objects:
            raise HttpError(412)
        if self.fail == 'before':
            self.fail = None
            raise OSError('reply lost before commit')
        blob = kwargs['Body'].read()
        self.objects[key] = {'data': blob, 'ContentLength': len(blob),
            'ContentType': kwargs['ContentType'], 'CacheControl': kwargs['CacheControl'],
            'Metadata': kwargs['Metadata']}
        if self.fail == 'after':
            self.fail = None
            raise OSError('reply lost after commit')
        if self.fail == 'collision':
            self.fail = None
            raise HttpError(412)
        return {}


class R2Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / 'pack'
        self.root.mkdir()
        self.catalog = {'id': 'app-test-pack-r1', 'actions': [], 'mediaDistribution': {
            'version': r2.VERSION, 'kind': 'r2-objects@1', 'baseUrl': r2.BASE_URL,
            'pathRule': 'relative-path', 'objectKeyPrefix': r2.PREFIX,
            'sourceCatalogSha256': r2.SOURCE_SHA, 'mediaFiles': 657}}
        for index in range(219):
            action = {'id': f'action-{index}', 'trainingDefinitionComplete': index < 211,
                      'files': {}}
            for role in ('video', 'cover', 'thumbnail'):
                suffix = 'mp4' if role == 'video' else 'webp'
                relative = f'media/action-{index}/action-{index}.{role}.{suffix}'
                path = self.root / relative
                path.parent.mkdir(exist_ok=True, parents=True)
                data = f'bytes:{relative}'.encode()
                path.write_bytes(data)
                action['files'][role] = {'path': relative, 'bytes': len(data),
                    'sha256': hashlib.sha256(data).hexdigest(), 'assetName': path.name,
                    'downloadUrl': r2.BASE_URL + relative}
            self.catalog['actions'].append(action)
        self.catalog['mediaDistribution']['mediaBytes'] = sum(
            f['bytes'] for a in self.catalog['actions'] for f in a['files'].values())
        self.sha = self.write_catalog()
        self.assets = r2.load_assets(self.root, self.sha)
        self.asset = self.assets[0]
        self.client = FakeS3()
        self.transport = r2.S3Transport(self.client)
        self.journal = r2.Journal(self.base / 'journal.json', {'catalogSha256': self.sha})
        self.addCleanup(self.journal.close)

    def write_catalog(self):
        blob = (json.dumps(self.catalog) + '\n').encode()
        (self.root / 'catalog.json').write_bytes(blob)
        return hashlib.sha256(blob).hexdigest()

    def upload(self):
        return r2.upload_one(self.transport, self.journal, self.asset, sleep=lambda _: None)

    def test_all_receipts_and_semantics_are_checked(self):
        self.assertEqual(len(self.assets), 658)
        self.assertEqual(self.assets[-1].path, 'catalog.json')
        self.assertEqual(r2.summary(self.assets)['semanticComplete'], 211)
        self.asset.local.write_bytes(b'changed')
        with self.assertRaises(r2.Conflict):
            r2.load_assets(self.root, self.sha)
        self.assertFalse(self.client.puts)

    def test_manifest_scope_and_approved_catalog_hash(self):
        for values in (('x' * 32, r2.BUCKET, r2.PREFIX),
                       (r2.ACCOUNT, 'other', r2.PREFIX),
                       (r2.ACCOUNT, r2.BUCKET, 'pack/r1-v2/')):
            with self.assertRaises(r2.R2Error):
                r2.scope(*values)
        with self.assertRaises(r2.Conflict):
            r2.load_assets(self.root, '0' * 64)
        self.catalog['mediaDistribution']['version'] = 'posehub-app-test-pack-r1-v2'
        with self.assertRaises(r2.R2Error):
            r2.load_assets(self.root, self.write_catalog())

    def test_duplicates_counts_paths_and_urls_are_rejected(self):
        first, last = self.catalog['actions'][0], self.catalog['actions'][-1]
        for alter, undo in (
            (lambda: last.update(id=first['id']), lambda: last.update(id='action-218')),
            (lambda: last.update(trainingDefinitionComplete=True),
             lambda: last.update(trainingDefinitionComplete=False)),
            (lambda: first['files']['video'].update(path='../escape.mp4'),
             lambda: first['files']['video'].update(path='media/action-0/action-0.video.mp4')),
            (lambda: first['files']['video'].update(downloadUrl='https://wrong.example/file'),
             lambda: first['files']['video'].update(downloadUrl=r2.BASE_URL + first['files']['video']['path']))):
            alter()
            with self.assertRaises(r2.R2Error):
                r2.load_assets(self.root, self.write_catalog())
            undo()

    def test_conditional_write_and_idempotent_resume(self):
        self.assertEqual(self.upload(), 'uploaded')
        self.assertEqual(self.upload(), 'identical')
        self.assertEqual(len(self.client.puts), 1)
        request = self.client.puts[0]
        self.assertEqual(request['IfNoneMatch'], '*')
        self.assertEqual(request['ContentType'], 'image/webp')
        self.assertEqual(request['CacheControl'], r2.CACHE_CONTROL)
        self.assertEqual(request['Key'], r2.PREFIX + self.asset.path)
        self.assertTrue(all(body.closed for body in self.client.bodies))
        saved = json.loads(self.journal.path.read_text('utf-8'))
        self.assertEqual(len(saved['attempts']), 1)
        self.assertEqual(saved['verified'][self.asset.path]['sha256'], self.asset.sha256)

    def test_digest_conflict_stops_without_put(self):
        self.upload()
        row = self.client.objects[r2.PREFIX + self.asset.path]
        row['data'] = b'x' * self.asset.size
        with self.assertRaises(r2.Conflict):
            self.upload()
        self.assertEqual(len(self.client.puts), 1)
        self.assertTrue(self.client.bodies[-1].closed)

    def test_header_or_digest_metadata_conflict_stops(self):
        self.upload()
        row = self.client.objects[r2.PREFIX + self.asset.path]
        row['Metadata'] = {'sha256': 'f' * 64}
        with self.assertRaises(r2.Conflict):
            self.upload()
        row['Metadata'] = {}
        row['ContentType'] = 'application/octet-stream'
        with self.assertRaises(r2.Conflict):
            self.upload()
        self.assertEqual(len(self.client.puts), 1)

    def test_unknown_response_reconciles_without_second_write(self):
        self.client.fail = 'after'
        self.assertEqual(self.upload(), 'reconciled')
        self.assertEqual(len(self.client.puts), 1)

    def test_unknown_before_commit_retries_only_conditionally(self):
        self.client.fail = 'before'
        self.assertEqual(self.upload(), 'uploaded')
        self.assertEqual(len(self.client.puts), 2)
        self.assertTrue(all(p['IfNoneMatch'] == '*' for p in self.client.puts))

    def test_competing_conditional_writer_is_reconciled(self):
        self.client.fail = 'collision'
        self.assertEqual(self.upload(), 'reconciled')
        self.assertEqual(len(self.client.puts), 1)

    def test_auth_failure_is_not_retried(self):
        with mock.patch.object(self.client, 'get_object', side_effect=HttpError(403)):
            with self.assertRaises(r2.RequestFailure) as raised:
                self.upload()
        self.assertEqual(raised.exception.status, 403)
        self.assertFalse(self.client.puts)

    def test_429_waits_and_then_reconciles(self):
        self.upload()
        original = self.client.get_object
        error = HttpError(429)
        error.response['ResponseMetadata']['HTTPHeaders'] = {'retry-after': '3'}
        with mock.patch.object(self.client, 'get_object', side_effect=[error, original(
                Bucket=r2.BUCKET, Key=r2.PREFIX + self.asset.path)]), mock.patch.object(r2.time, 'sleep') as sleep:
            self.assertEqual(r2.upload_one(self.transport, self.journal, self.asset, sleep), 'identical')
        sleep.assert_called_once_with(3.0)

    def test_journal_identity_and_exclusive_lock(self):
        with self.assertRaises(OSError):
            r2.Journal(self.journal.path, {'catalogSha256': self.sha})
        self.upload()
        self.journal.close()
        with self.assertRaises(r2.Conflict):
            r2.Journal(self.journal.path, {'catalogSha256': 'other'})

    def test_receipts_cannot_be_written_in_git(self):
        root = self.base / 'checkout'
        root.mkdir()
        (root / '.git').write_text('gitdir: elsewhere', encoding='utf-8')
        with self.assertRaises(r2.R2Error):
            r2.Journal(root / 'r2-receipts.json', {})

    def test_backup_is_deterministic_and_never_overwrites(self):
        first, second = self.base / 'one.zip', self.base / 'two.zip'
        one = r2.backup_zip(self.assets, first)
        two = r2.backup_zip(self.assets, second)
        self.assertEqual(one['sha256'], two['sha256'])
        self.assertEqual(r2.backup_zip(self.assets, first)['sha256'], one['sha256'])
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(len(archive.infolist()), 658)
            self.assertEqual([i.filename for i in archive.infolist()], sorted(a.path for a in self.assets))
            self.assertTrue(all(i.create_system == 0 and not i.extra for i in archive.infolist()))
            for asset in self.assets:
                self.assertEqual(hashlib.sha256(archive.read(asset.path)).hexdigest(), asset.sha256)
        second.write_bytes(b'keep existing')
        with self.assertRaises(r2.Conflict):
            r2.backup_zip(self.assets, second)
        self.assertEqual(second.read_bytes(), b'keep existing')

    def test_smoke_upload_does_not_publish_catalog(self):
        with mock.patch('builtins.print'):
            result = r2.publish(self.assets, self.transport, self.journal, workers=2, limit=2)
        self.assertEqual(len(result), 2)
        self.assertNotIn(r2.PREFIX + 'catalog.json', self.client.objects)

    def test_catalog_is_published_only_after_all_media_verify(self):
        with mock.patch('builtins.print'), mock.patch.object(self.journal, 'record'):
            result = r2.publish(self.assets, self.transport, self.journal, workers=4)
        self.assertEqual(len(result), 658)
        self.assertEqual(self.client.puts[-1]['Key'], r2.PREFIX + 'catalog.json')


if __name__ == '__main__':
    unittest.main()
