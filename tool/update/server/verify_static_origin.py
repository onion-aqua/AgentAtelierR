#!/usr/bin/env python3
"""Verify actual HTTPS download semantics without generating/publishing a release.

Only a public health/probe file is used. Output omits the private origin URL.
"""
import argparse
import hashlib
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

PROBE = b'AgentAtelierR self-hosted update transport probe.\n' * 4


def verify(base_url, check_relay=False):
    origin = urllib.parse.urlsplit(base_url)
    if (origin.scheme != 'https' or not origin.hostname or origin.username or
            origin.password or origin.query or origin.fragment or
            origin.path.rstrip('/') != '/updates/agentatelier'):
        raise ValueError('expected a credential-free HTTPS update base URL')
    context = ssl.create_default_context()
    base_url = base_url.rstrip('/') + '/'
    checks = []

    def request(path, method='GET', headers=None, absolute=False):
        address = urllib.parse.urlunsplit((origin.scheme, origin.netloc, path, '', '')) if absolute else base_url + path
        req = urllib.request.Request(address, method=method, headers={'Accept-Encoding': 'identity', **(headers or {})})
        try:
            response = urllib.request.urlopen(req, context=context, timeout=25)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            if response.geturl() != address:
                raise AssertionError('unexpected redirect')
            return response.status, response.headers, response.read()

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append({'check': name, 'passed': True})

    code, headers, data = request('healthz')
    check('trusted_https_health', code == 200 and data == b'agentatelier-updates ready\n')
    check('health_not_cached', headers.get('Cache-Control') == 'no-store')
    probe = 'diagnostics/download-probe.txt'
    code, headers, data = request(probe)
    etag = headers.get('ETag')
    check('probe_hash', code == 200 and data == PROBE and bool(etag))
    check('security_headers', headers.get('Strict-Transport-Security') is not None and headers.get('X-Content-Type-Options') == 'nosniff')
    code, head_headers, data = request(probe, method='HEAD')
    check('head_length_etag', code == 200 and not data and int(head_headers.get('Content-Length', '-1')) == len(PROBE) and head_headers.get('ETag') == etag)
    code, headers, data = request(probe, headers={'Range': 'bytes=0-31'})
    check('range_206', code == 206 and data == PROBE[:32] and headers.get('Content-Range') == f'bytes 0-31/{len(PROBE)}')
    code, headers, data = request(probe, headers={'Range': 'bytes=32-63', 'If-Range': etag})
    check('matching_if_range_206', code == 206 and data == PROBE[32:64])
    code, headers, data = request(probe, headers={'Range': 'bytes=0-31', 'If-Range': '"invalid-etag"'})
    check('stale_if_range_full_200', code == 200 and data == PROBE)
    code, headers, data = request(probe, headers={'If-None-Match': etag})
    check('conditional_etag_304', code == 304 and not data)
    code, headers, data = request('artifacts/transport-probe-' + hashlib.sha256(PROBE).hexdigest() + '.txt')
    check('immutable_artifact_cache', code == 200 and data == PROBE and headers.get('Cache-Control') == 'public, max-age=31536000, immutable')
    code, headers, data = request('channels/android/stable.json')
    check('empty_channel_unpublished', code == 404 and headers.get('Cache-Control') == 'no-store')
    for path in ['.env', 'releases/test.pem', 'private/config.json', 'diagnostics/', 'missing-file', 'resources/staging/file.json']:
        code, headers, data = request(path)
        check('blocked_or_missing_' + path, code in (403, 404))
    code, headers, data = request(probe, method='POST')
    check('public_upload_rejected', code in (403, 405))
    if check_relay:
        for path, expected in [('/health', 200), ('/v1/state', 401), ('/v1/ws', 401)]:
            code, headers, data = request(path, absolute=True)
            check('relay_' + path, code == expected)
    return {'tls_verified': True, 'checks': checks, 'passed_count': len(checks),
            'probe_sha256': hashlib.sha256(PROBE).hexdigest(),
            'release_manifest_tested': False, 'apk_install_tested': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--check-relay', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.base_url, args.check_relay), indent=2))
    except Exception as error:
        # urllib exceptions can contain the private origin. Never print them.
        stage = str(error) if isinstance(error, AssertionError) else type(error).__name__
        print('HTTPS verification failed: ' + stage, file=sys.stderr)
        sys.exit(1)
