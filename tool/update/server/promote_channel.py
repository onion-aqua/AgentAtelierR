#!/usr/bin/env python3
"""Verify staged files and an Ed25519 signature before atomically publishing.

The upload directory is private, under /srv/agentatelier-updates/staging.
Only a public verification key is required; signing always happens locally.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path('/srv/agentatelier-updates')
PUBLIC = ROOT / 'public'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def safe_path(root, relative):
    if not isinstance(relative, str):
        raise ValueError('publication path must be text')
    p = PurePosixPath(relative)
    if p.is_absolute() or not p.parts or any(x in ('', '.', '..') or x.startswith('.') for x in relative.split('/')) or '\\' in relative:
        raise ValueError('unsafe publication path')
    target = root.joinpath(*p.parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError('publication path escapes managed root')
    for ancestor in (target, *target.parents):
        if ancestor == root.parent:
            break
        if ancestor.is_symlink():
            raise ValueError('publication paths cannot be symlinks')
    return target


def regular_file(path):
    if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
        raise ValueError('publication input must be a regular file')
    return path


def read_json(path):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate JSON field')
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError('non-finite JSON constant')

    return json.loads(regular_file(path).read_bytes(), object_pairs_hook=unique_pairs,
                      parse_constant=invalid_constant)


def canonical_bytes(value):
    def ordered(item):
        if item is None or type(item) in (bool, int, str):
            return item
        if isinstance(item, list):
            return [ordered(child) for child in item]
        if isinstance(item, dict) and all(isinstance(key, str) for key in item):
            return {key: ordered(item[key]) for key in sorted(item, key=lambda key: key.encode('utf-16-be'))}
        raise ValueError('unsupported canonical JSON value')
    return json.dumps(ordered(value), separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def sync_directory(path):
    # Windows is used only for isolated local tests; the deployed host is Linux.
    if os.name != 'posix':
        return
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', suffix='.part', dir=path.parent)
    tmp = Path(temporary)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        tmp.chmod(0o644)
        os.replace(tmp, path)
        sync_directory(path.parent)
    finally:
        tmp.unlink(missing_ok=True)


def matches(path, sha256, size):
    return (regular_file(path).stat().st_size == size and digest(path) == sha256)


def publish_immutable(src, dst, sha256, size):
    """Copy to an independent inode, flush, and publish without overwriting."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        if not matches(dst, sha256, size):
            raise ValueError('immutable artifact conflict')
        return
    fd, temporary = tempfile.mkstemp(prefix='.' + dst.name + '.', suffix='.part', dir=dst.parent)
    tmp = Path(temporary)
    try:
        copied = 0
        copied_digest = hashlib.sha256()
        with os.fdopen(fd, 'wb') as output, regular_file(src).open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                copied += len(block)
                if copied > size:
                    raise ValueError('staged artifact changed during publication')
                copied_digest.update(block)
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        if copied != size or copied_digest.hexdigest() != sha256:
            raise ValueError('staged artifact changed during publication')
        tmp.chmod(0o644)
        try:
            # The only shared inode is the private temporary copy, removed below.
            # The upload source remains independent and safe to overwrite later.
            os.link(tmp, dst)
        except FileExistsError:
            if not matches(dst, sha256, size):
                raise ValueError('immutable artifact conflict')
        sync_directory(dst.parent)
    finally:
        tmp.unlink(missing_ok=True)


def local_url_path(value):
    if not isinstance(value, str):
        raise ValueError('artifact URL must be text')
    parsed = urlsplit(value)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError('artifact URL must use authenticated HTTPS')
    prefix = '/updates/agentatelier/'
    path = unquote(parsed.path, errors='strict')
    if not path.startswith(prefix):
        return None
    relative = path[len(prefix):]
    safe_path(PUBLIC, relative)
    if relative.split('/')[0] not in ('artifacts', 'resources', 'releases', 'notes'):
        raise ValueError('signed reference is outside immutable publication paths')
    return relative


def promote(stage, expected_key_id, expected_public_key_sha256, required_channel=None):
    if (not isinstance(expected_key_id, str) or
            not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', expected_key_id) or
            not isinstance(expected_public_key_sha256, str) or
            not re.fullmatch(r'[0-9a-f]{64}', expected_public_key_sha256)):
        raise ValueError('a trusted public key identity and PEM hash are required')
    staging_root = ROOT / 'staging'
    if (stage.parent != staging_root or stage.name in ('.', '..') or
            not re.fullmatch(r'[a-zA-Z0-9._-]+', stage.name) or stage.is_symlink() or
            ROOT.is_symlink() or PUBLIC.is_symlink() or staging_root.is_symlink() or
            stage.resolve(strict=True).parent != staging_root.resolve(strict=True)):
        raise ValueError('unexpected staging directory')
    plan = read_json(safe_path(stage, 'upload-plan.json'))
    manifest_file = regular_file(safe_path(stage, 'manifest.json'))
    raw = manifest_file.read_bytes()
    envelope = read_json(manifest_file)
    payload = envelope['payload']
    if payload['canonicalization'] != 'aar-cjson-v1' or payload['platform'] != 'android':
        raise ValueError('unsupported manifest')
    channel = payload['channel']
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,63}', channel):
        raise ValueError('invalid channel')
    if (required_channel is not None and
            (not isinstance(required_channel, str) or
             not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,63}', required_channel) or
             channel != required_channel)):
        raise ValueError('manifest channel differs from explicitly required channel')
    canonical = canonical_bytes(payload)
    canonical_file = regular_file(safe_path(stage, 'payload.canonical.json'))
    if canonical != canonical_file.read_bytes():
        raise ValueError('canonical payload differs from signed bytes')
    signature = envelope['signature']
    if signature['algorithm'] != 'Ed25519' or signature['canonicalization'] != 'aar-cjson-v1' or signature['signed_object'] != 'payload':
        raise ValueError('unsupported signature')
    if signature['key_id'] != expected_key_id:
        raise ValueError('manifest signer differs from the trusted key identity')
    signature_bytes = base64.b64decode(signature['value_base64'], validate=True)
    if len(signature_bytes) != 64:
        raise ValueError('invalid signature length')
    public_key = regular_file(safe_path(stage, 'public-key.pem'))
    if digest(public_key) != expected_public_key_sha256:
        raise ValueError('staged public key differs from the trusted local PEM')
    fd, signature_name = tempfile.mkstemp(prefix='.signature-', dir=stage)
    try:
        with os.fdopen(fd, 'wb') as signature_file:
            signature_file.write(signature_bytes)
        subprocess.run(['openssl', 'pkeyutl', '-verify', '-rawin', '-pubin', '-inkey', str(public_key), '-in', str(canonical_file), '-sigfile', signature_name], check=True, capture_output=True)
    finally:
        Path(signature_name).unlink(missing_ok=True)
    seq = payload['release_seq']
    if type(seq) is not int or seq <= 0:
        raise ValueError('invalid sequence')
    channel_file = safe_path(PUBLIC, 'channels/android/' + channel + '.json')
    if channel_file.exists():
        previous = read_json(channel_file)['payload']
        if previous['release_seq'] > seq or (previous['release_seq'] == seq and channel_file.read_bytes() != raw):
            raise ValueError('channel replay or release identity conflict')
    files = plan['files']
    if not isinstance(files, list) or not files:
        raise ValueError('no staged artifacts')
    verified = []
    seen = {}
    for record in files:
        relative = record['path']
        if relative in seen or relative.split('/')[0] not in ('artifacts', 'resources', 'releases', 'notes'):
            raise ValueError('invalid immutable target')
        seen[relative] = record
        src = safe_path(stage / 'files', relative)
        dst = safe_path(PUBLIC, relative)
        if (not isinstance(record['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', record['sha256']) or
                type(record['size']) is not int or record['size'] <= 0 or
                not matches(src, record['sha256'], record['size'])):
            raise ValueError('uploaded bytes differ from local artifact')
        if dst.exists() and not matches(dst, record['sha256'], record['size']):
            raise ValueError('immutable artifact conflict')
        verified.append((src, dst, record['sha256'], record['size']))

    def reference(urls, expected_hash=None, expected_size=None):
        if not isinstance(urls, list) or not urls:
            raise ValueError('signed artifact has no URLs')
        if expected_hash is not None and (not isinstance(expected_hash, str) or not re.fullmatch(r'[0-9a-f]{64}', expected_hash)):
            raise ValueError('invalid signed artifact hash')
        if expected_size is not None and (type(expected_size) is not int or expected_size <= 0):
            raise ValueError('invalid signed artifact size')
        found = []
        for url in urls:
            relative = local_url_path(url)
            if relative is None:
                continue
            record = seen.get(relative)
            if record is not None:
                if ((expected_hash is not None and record['sha256'] != expected_hash) or
                        (expected_size is not None and record['size'] != expected_size)):
                    raise ValueError('upload plan differs from signed reference')
                found.append(safe_path(stage / 'files', relative))
            else:
                existing = regular_file(safe_path(PUBLIC, relative))
                if expected_size is not None and existing.stat().st_size != expected_size:
                    raise ValueError('existing signed artifact size differs')
                if expected_hash is not None and digest(existing) != expected_hash:
                    raise ValueError('existing signed artifact hash differs')
                found.append(existing)
        if not found:
            raise ValueError('signed reference has no verified local publication copy')
        return found[0]

    target = payload.get('target_apk')
    snapshot = payload.get('resource_snapshot')
    if target is None and snapshot is None:
        raise ValueError('signed release has no update target')
    if target is not None:
        reference(target['urls'], target['sha256'], target['size'])
    for delta in payload['apk_deltas']:
        reference(delta['urls'], delta['patch_sha256'], delta['size'])
    if snapshot is not None:
        resource_file = reference([snapshot['manifest_url']], snapshot['manifest_sha256'], snapshot['size'])
        resource = read_json(resource_file)
        if (canonical_bytes(resource) != resource_file.read_bytes() or
                resource['snapshot_id'] != snapshot['id'] or
                resource['schema_version'] != snapshot['schema_version'] or
                resource['asset_key_id'] != snapshot['asset_key_id'] or
                resource['compatible_runtime_ids'] != snapshot['compatible_runtime_ids'] or
                resource['resource_api_version'] != payload['resource_api_version'] or
                resource['canonicalization'] != 'aar-cjson-v1'):
            raise ValueError('resource manifest differs from signed snapshot')
        for obj in resource['objects']:
            reference(obj['urls'], obj['sha256'], obj['size'])
    cached_notes = payload['notes'].get('cached_markdown_url')
    if cached_notes is not None:
        reference([cached_notes])
    release_manifest = f"releases/{payload['release_id']}/manifest.json"
    if release_manifest not in seen or safe_path(stage / 'files', release_manifest).read_bytes() != raw:
        raise ValueError('immutable release manifest missing or different')
    for src, dst, sha256, size in verified:
        publish_immutable(src, dst, sha256, size)
    if channel_file.exists() and channel_file.read_bytes() != raw:
        history = safe_path(ROOT, 'channel-history')
        history.mkdir(mode=0o700, exist_ok=True)
        prior = read_json(channel_file)['payload']['release_seq']
        previous_file = safe_path(ROOT, f'channel-history/{channel}-{prior}.json')
        if previous_file.exists() and previous_file.read_bytes() != channel_file.read_bytes():
            raise ValueError('channel history conflict')
        atomic_json(previous_file, channel_file.read_bytes())
    atomic_json(channel_file, raw)
    print(json.dumps({'published': True, 'release_id': payload['release_id'], 'release_seq': seq,
                      'verified_files': len(verified), 'manifest_sha256': hashlib.sha256(raw).hexdigest(),
                      'published_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', required=True)
    parser.add_argument('--expected-key-id', required=True)
    parser.add_argument('--expected-public-key-sha256', required=True)
    parser.add_argument('--required-channel', required=True)
    args = parser.parse_args()
    if os.name != 'posix':
        raise ValueError('publication requires a Linux host')
    import fcntl
    if ROOT.is_symlink() or not ROOT.is_dir():
        raise ValueError('unexpected publication root')
    lock_path = ROOT / '.promotion.lock'
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        promote(Path(args.stage), args.expected_key_id, args.expected_public_key_sha256, args.required_channel)
    finally:
        os.close(lock_fd)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Publication failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
