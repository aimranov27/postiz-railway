// Small helpers used by railway-entrypoint.sh. Lives in /app/railway so that
// require() resolves Postiz's own copy of @temporalio/client.
//
//   wait-temporal <seconds>      wait until the Temporal namespace answers
//   wait-http <url> <seconds>    wait until a URL answers with a non-5xx status
//   seed                         create the first account from env vars
//   pollers                      print how many workers poll the "main" queue
'use strict';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const log = (msg) => console.log(`[railway-entrypoint] ${msg}`);

const temporalOptions = () => ({
  address: process.env.TEMPORAL_ADDRESS || 'localhost:7233',
  ...(process.env.TEMPORAL_TLS === 'true' ? { tls: true } : {}),
  ...(process.env.TEMPORAL_API_KEY ? { apiKey: process.env.TEMPORAL_API_KEY } : {}),
  connectTimeout: '5s',
});
const namespace = process.env.TEMPORAL_NAMESPACE || 'default';

async function withTemporal(fn) {
  const { Connection } = require('@temporalio/client');
  const connection = await Connection.connect(temporalOptions());
  try {
    return await fn(connection);
  } finally {
    await connection.close().catch(() => {});
  }
}

async function waitTemporal(seconds) {
  const deadline = Date.now() + seconds * 1000;
  let lastError = '';
  while (Date.now() < deadline) {
    try {
      await withTemporal((c) => c.workflowService.describeNamespace({ namespace }));
      return true;
    } catch (err) {
      lastError = err && err.message ? err.message : String(err);
    }
    await sleep(3000);
  }
  log(`Temporal at ${temporalOptions().address} is not ready: ${lastError}`);
  return false;
}

async function waitHttp(url, seconds) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
      if (res.status < 500) return true;
    } catch {}
    await sleep(2000);
  }
  return false;
}

async function seed() {
  const email = (process.env.POSTIZ_ADMIN_EMAIL || '').trim();
  const password = process.env.POSTIZ_ADMIN_PASSWORD || '';
  const company = (process.env.POSTIZ_ADMIN_COMPANY || 'My Workspace').trim();
  const backend = 'http://127.0.0.1:3000';

  if (!email || !password) {
    log('WARNING: POSTIZ_ADMIN_EMAIL and POSTIZ_ADMIN_PASSWORD are not set.');
    log('WARNING: The first person to open this URL can create the account.');
    return true;
  }
  if (process.env.DISABLE_REGISTRATION !== 'true') {
    log('WARNING: DISABLE_REGISTRATION is not "true", so anyone can sign up. Skipping account creation.');
    return true;
  }

  // With DISABLE_REGISTRATION=true, Postiz only allows a sign-up while no
  // organisation exists. So "can register" means this is a fresh install.
  const status = await fetch(`${backend}/auth/can-register`).then((r) => r.json());
  if (!status.register) {
    log('An account already exists. Leaving it unchanged.');
    return true;
  }

  const res = await fetch(`${backend}/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, company, provider: 'LOCAL' }),
  });
  const body = await res.text();
  if (res.status === 200 || res.status === 201) {
    if (body.includes('"activate":true')) {
      log(`Account ${email} created. An email provider is configured, so it must be activated from the email Postiz sent.`);
    } else {
      log(`Account ${email} created.`);
    }
    return true;
  }
  log(`ERROR: could not create the account ${email} (HTTP ${res.status}): ${body.slice(0, 300)}`);
  return false;
}

async function pollers() {
  const response = await withTemporal((c) =>
    c.workflowService.describeTaskQueue({
      namespace,
      taskQueue: { name: 'main', kind: 1 },
      taskQueueType: 1,
    })
  );
  console.log((response.pollers || []).length);
  return true;
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
    case 'wait-temporal':
      return waitTemporal(Number(args[0] || 300));
    case 'wait-http':
      return waitHttp(args[0], Number(args[1] || 300));
    case 'seed':
      return seed();
    case 'pollers':
      return pollers();
    default:
      console.error('usage: railway-helper.cjs wait-temporal|wait-http|seed|pollers');
      return false;
  }
}

main().then(
  (ok) => process.exit(ok ? 0 : 1),
  (err) => {
    console.error(`[railway-entrypoint] ${err && err.stack ? err.stack : err}`);
    process.exit(1);
  }
);
