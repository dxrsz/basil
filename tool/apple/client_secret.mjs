#!/usr/bin/env node
// Generates the "Secret Key" Supabase needs for Sign in with Apple: an ES256
// JWT signed with your Sign in with Apple .p8 key. Runs locally; the key never
// leaves your machine. Apple caps the lifetime at 6 months, so re-run before
// it expires (the expiry date is printed).
//
//   node tool/apple/client_secret.mjs --p8 ~/AuthKey_ABC123.p8 \
//     --key-id ABC123 --team-id TEAM123456 --client-id app.basil.signin

import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
for (const k of ['p8', 'key-id', 'team-id', 'client-id']) {
  if (!args[k]) {
    console.error(`missing --${k}\nusage: node client_secret.mjs --p8 AuthKey_XXX.p8 --key-id XXX --team-id YYY --client-id app.basil.signin`);
    process.exit(1);
  }
}

const b64url = (b) => Buffer.from(b).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const exp = now + 180 * 24 * 60 * 60 - 60; // just under Apple's 6-month max

const header = { alg: 'ES256', kid: args['key-id'], typ: 'JWT' };
const payload = { iss: args['team-id'], iat: now, exp, aud: 'https://appleid.apple.com', sub: args['client-id'] };
const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;

const key = createPrivateKey(readFileSync(args.p8.replace(/^~/, homedir())));
const sig = sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' });

console.log(`${input}.${b64url(sig)}`);
console.error(`\nExpires ${new Date(exp * 1000).toDateString()}. Set a reminder to regenerate before then.`);
