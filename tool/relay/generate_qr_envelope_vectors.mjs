// TEST FIXTURES ONLY. Fixed nonces must never be used for real pairing codes.
// This independent Node implementation provides reusable Node -> Dart vectors.
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const prefix = 'ryzasync:v2:';
const seed = 'ryzasync/qr-envelope/v2/public-compat-key';
const key = createHash('sha256').update(seed, 'utf8').digest();
const target = fileURLToPath(new URL('../../test/relay/fixtures/qr-envelope-v2.json', import.meta.url));
const examples = [
  ['complete_utf8_pairing', '000102030405060708090a0b', {
    type: 'agent-relay-pair', v: 1,
    server_base_url: 'https://relay.example.test',
    pairing_id: '00000000-0000-4000-8000-000000000002',
    pairing_secret: 'a'.repeat(64), expires_at: '2030-01-01T00:00:00.000Z',
    binding_ttl_seconds: 259200, auto_confirm: true, pc_name: '互通测试-PC',
  }],
  ['legacy_fields', 'f0e0d0c0b0a0908070605040', {
    type: 'agent-relay-pair', v: 1,
    server_base_url: 'https://relay.example.test',
    pairing_id: '00000000-0000-4000-8000-000000000002',
    pairing_secret: 'b'.repeat(64),
  }],
];
function encode(plaintext, nonce) {
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.from(prefix, 'utf8'));
  const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  return prefix + Buffer.concat([nonce, encrypted, cipher.getAuthTag()]).toString('base64url');
}
const fixture = {
  schema_version: 1, algorithm: 'AES-256-GCM', prefix,
  aad_utf8: prefix, key_seed_utf8: seed, derived_key_hex: key.toString('hex'),
  vectors: examples.map(([name, nonce_hex, payload]) => {
    const plaintext_utf8 = JSON.stringify(payload);
    const envelope = encode(plaintext_utf8, Buffer.from(nonce_hex, 'hex'));
    const bytes = Buffer.from(envelope.slice(prefix.length), 'base64url');
    const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
    decipher.setAAD(Buffer.from(prefix, 'utf8'));
    decipher.setAuthTag(bytes.subarray(-16));
    const restored = Buffer.concat([decipher.update(bytes.subarray(12, -16)), decipher.final()]);
    if (restored.toString('utf8') !== plaintext_utf8) throw Error('Fixture mismatch');
    return { name, nonce_hex, plaintext_utf8, envelope };
  }),
};
const source = JSON.stringify(fixture, null, 2) + '\n';
if (process.argv.includes('--verify')) {
  if (readFileSync(target, 'utf8') !== source) throw Error('Stale QR fixture');
} else {
  writeFileSync(target, source, 'utf8');
}
// Exercise the independent producer with secure random nonces too.
const randomCodes = new Set(Array.from({ length: 16 }, () => encode('test', randomBytes(12))));
if (randomCodes.size !== 16) throw Error('Nonce reuse');
console.log(JSON.stringify({ passed: true, fixed_vectors: fixture.vectors.length, random_nonces: randomCodes.size }));
