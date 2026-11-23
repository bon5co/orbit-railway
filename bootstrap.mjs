// First-boot setup for Orbit, run by the web service once the app answers /api/health:
//   1. create the S3 bucket on the storage service (idempotent);
//   2. create the one admin account from ADMIN_EMAIL / ADMIN_PASSWORD (idempotent: sign in first, sign up only when that fails);
//   3. create the first workspace for that account when it has none.
// Sign-up for everyone else is closed by ALLOWED_EMAIL_DOMAINS, which railway-boot.sh sets to the domain of ADMIN_EMAIL.
import { CreateBucketCommand, HeadBucketCommand, S3Client } from '@aws-sdk/client-s3';

const base = 'http://127.0.0.1:3000';
const origin = new URL(process.env.BETTER_AUTH_URL).origin;
const email = process.env.ADMIN_EMAIL;
const password = process.env.ADMIN_PASSWORD;
const log = (message) => console.log(`[orbit-bootstrap] ${message}`);

async function ensureBucket() {
  const client = new S3Client({
    endpoint: process.env.S3_ENDPOINT,
    region: process.env.S3_REGION,
    forcePathStyle: true,
    credentials: { accessKeyId: process.env.S3_ACCESS_KEY_ID, secretAccessKey: process.env.S3_SECRET_ACCESS_KEY },
  });
  const Bucket = process.env.S3_BUCKET;
  try {
    await client.send(new HeadBucketCommand({ Bucket }));
    return;
  } catch {
    // not there yet
  }
  try {
    await client.send(new CreateBucketCommand({ Bucket }));
  } catch (error) {
    if (!['BucketAlreadyOwnedByYou', 'BucketAlreadyExists'].includes(error.name)) throw error;
  }
  await client.send(new HeadBucketCommand({ Bucket }));
}

async function call(method, path, body, cookie) {
  const response = await fetch(base + path, {
    method,
    headers: { 'content-type': 'application/json', origin, ...(cookie ? { cookie } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const cookies = response.headers.getSetCookie().map((line) => line.split(';')[0]).join('; ');
  return { status: response.status, cookies, json: await response.json().catch(() => null) };
}

async function signIn() {
  const result = await call('POST', '/api/auth/sign-in/email', { email, password });
  return result.status === 200 && result.cookies !== '' ? result.cookies : null;
}

async function main() {
  await ensureBucket();
  log(`bucket ${process.env.S3_BUCKET} ready`);
  let cookie = await signIn();
  if (cookie === null) {
    const created = await call('POST', '/api/auth/sign-up/email', { email, password, name: 'Admin' });
    log(`sign-up ${created.status} ${JSON.stringify(created.json)}`);
    cookie = await signIn();
  }
  if (cookie === null) throw new Error('could not sign in as the admin account');
  log('admin account ready');
  const list = await call('GET', '/api/organizations', undefined, cookie);
  if (list.status !== 200) throw new Error(`organizations list ${list.status}`);
  if (list.json.organizations.length === 0) {
    const made = await call('POST', '/api/organizations', { name: 'Main', slug: 'main-workspace' }, cookie);
    if (made.status >= 300) throw new Error(`workspace create ${made.status} ${JSON.stringify(made.json)}`);
    log('workspace main-workspace created');
  }
  log('done');
}

let attempt = 0;
for (;;) {
  attempt += 1;
  try {
    await main();
    break;
  } catch (error) {
    log(`attempt ${attempt} failed: ${error.message}`);
    if (attempt >= 40) {
      log('giving up');
      process.exit(1);
    }
    await new Promise((resolve) => setTimeout(resolve, 30000));
  }
}
