import test from 'node:test';
import assert from 'node:assert/strict';
import { client, markerName, repair, resolveSource } from './jules-ci.mjs';

const sha = 'a'.repeat(40);
function fixture() {
  const state = { calls: [], checks: [], moved: false, run: {
    id: 42, run_attempt: 1, status: 'completed', conclusion: 'failure', name: 'Android',
    path: '.github/workflows/android.yml', event: 'push', head_sha: sha, head_branch: 'main',
    html_url: 'https://github.com/owner/repo/actions/runs/42',
    repository: { full_name: 'owner/repo' }, head_repository: { full_name: 'owner/repo' },
    actor: { login: 'owner' }, triggering_actor: { login: 'owner' },
  }, jobs: [{ name: 'test', conclusion: 'failure', steps: [{ name: 'Run tests', conclusion: 'failure', started_at: '2026-10-20T00:00:00Z', number: 3 }] }], prs: [], permission: 'write' };
  const gh = async (path, method = 'GET', body) => {
    state.calls.push({ path, method, body });
    if (path.endsWith('/actions/runs/42')) return state.run;
    if (path.includes('/jobs?')) return { jobs: state.jobs };
    if (path.includes('/branches/')) return { commit: { sha: state.moved ? 'b'.repeat(40) : sha } };
    if (path.includes('/pulls?')) return state.prs;
    if (path.endsWith('/permission')) return { permission: state.permission };
    if (path.includes('/check-runs?')) {
      const page = Number(new URL(`https://example.com/${path}`).searchParams.get('page'));
      return { check_runs: state.checks.slice((page - 1) * 100, page * 100) };
    }
    if (path.endsWith('/check-runs') && method === 'POST') { state.checks.push({ ...body, id: 7 }); return { id: 7 }; }
    if (method === 'PATCH') return {};
    throw new Error(`Unexpected GitHub request: ${path}`);
  };
  const jules = async (path, method = 'GET') => {
    state.calls.push({ service: 'jules', path, method });
    if (path.startsWith('sources?')) return { sources: [{ name: 'sources/github/owner/repo', githubRepo: { owner: 'owner', repo: 'repo' } }] };
    if (method === 'POST') { assert.equal(state.checks.length, 1); return { name: 'sessions/123', url: 'https://jules.google.com/session/123', state: 'QUEUED' }; }
    return { state: 'COMPLETED', outputs: [{ pullRequest: { url: 'https://github.com/owner/repo/pull/1' } }] };
  };
  return { state, args: { gh, jules, repo: 'owner/repo', runId: 42, dryRun: false, enabled: true, source: 'sources/test', hasKey: true, sleep: async () => {} } };
}

test('read-only preflight needs no Jules credentials and makes zero writes', async () => {
  const { args, state } = fixture();
  assert.equal((await repair({ ...args, dryRun: true, hasKey: false })).outcome, 'eligible');
  assert.ok(state.calls.every(c => c.method === 'GET' && !c.service));
});

for (const [scenario, change, reason] of [
  ['success', s => s.run.conclusion = 'success', 'not a completed failure'],
  ['unallowlisted', s => s.run.path = '.github/workflows/evil.yml', 'workflow not allowlisted'],
  ['stale registered workflow', s => { s.run.name = 'Build Android APK'; s.run.path = '.github/workflows/build-apk.yml'; }, 'workflow not allowlisted'],
  ['fork', s => s.run.head_repository.full_name = 'outsider/repo', 'foreign repository'],
  ['stale SHA', s => s.moved = true, 'branch moved since failure'],
  ['no started step', s => s.jobs[0].steps = [], 'infrastructure failure or no started failing step'],
  ['setup failure', s => s.jobs[0].steps[0].name = 'Set up job', 'infrastructure failure or no started failing step'],
  ['Jules branch', s => s.run.head_branch = 'jules-ci/repair', 'Jules origin'],
  ['Jules PR despite human actor', s => s.prs = [{ user: { login: 'google-labs-jules[bot]' } }], 'Jules repair PR'],
  ['untrusted actor', s => s.permission = 'read', 'actor lacks write access'],
]) test(`rejects ${scenario} without writing`, async () => {
  const { args, state } = fixture(); change(state);
  assert.equal((await repair(args)).reason, reason);
  assert.ok(state.calls.every(c => c.method === 'GET' && !c.service));
});

test('disabled activation never contacts Jules', async () => {
  const { args, state } = fixture();
  assert.equal((await repair({ ...args, enabled: false })).reason, 'activation disabled');
  assert.ok(state.calls.every(c => c.method === 'GET' && !c.service));
});
test('dedupe reads beyond first page and includes old attempts', async () => {
  const { args, state } = fixture();
  state.checks = [...Array.from({ length: 100 }, () => ({ name: 'other' })), { name: markerName }];
  assert.equal((await repair(args)).reason, 'submission already attempted for SHA');
  assert.ok(state.calls.some(c => c.path.includes('filter=all&per_page=100&page=2')));
});
test('serialized workflows/reruns submit only once, marker precedes POST', async () => {
  const { args, state } = fixture();
  assert.equal((await repair(args)).outcome, 'completed');
  state.run.name = 'iOS'; state.run.path = '.github/workflows/ios.yml'; state.run.run_attempt = 2;
  assert.equal((await repair(args)).reason, 'submission already attempted for SHA');
  assert.equal(state.calls.filter(c => c.service === 'jules' && c.method === 'POST').length, 1);
});
test('ambiguous session POST keeps marker and cannot be retried', async () => {
  const { args, state } = fixture();
  const original = args.jules;
  args.jules = (path, method) => method === 'POST' ? Promise.reject(new Error('transport failed')) : original(path, method);
  await assert.rejects(repair(args), /transport failed/);
  assert.equal(state.checks.length, 1);
  assert.equal((await repair(args)).reason, 'submission already attempted for SHA');
});
test('branch moving after reservation consumes attempt without POST', async () => {
  const { args, state } = fixture(); const original = args.gh;
  args.gh = async (...call) => { const value = await original(...call); if (call[1] === 'POST') state.moved = true; return value; };
  assert.equal((await repair(args)).reason, 'branch moved after reservation; attempt consumed');
  assert.equal(state.calls.filter(c => c.service && c.method === 'POST').length, 0);
});
test('bounded polling reports submitted, not completed, on pending sessions', async () => {
  const { args } = fixture(); let polls = 0; const original = args.jules;
  args.jules = async (path, method) => path.startsWith('sessions/') ? (polls++, { state: 'IN_PROGRESS' }) : original(path, method);
  assert.equal((await repair(args)).outcome, 'submitted'); assert.equal(polls, 6);
});
test('API HTTP errors omit sensitive response body and never retry', async () => {
  let calls = 0;
  const api = client('https://example.com', {}, async () => { calls++; return new Response('secret-value', { status: 403 }); });
  await assert.rejects(api('sessions', 'POST', {}), /^Error: POST request failed: HTTP 403$/);
  assert.equal(calls, 1);
});

test('source discovery follows pagination and accepts documented nested name', async () => {
  const calls = [];
  const source = await resolveSource(async path => {
    calls.push(path);
    return calls.length === 1 ? { sources: [], nextPageToken: 'page/2' } : { sources: [{ name: 'sources/github/owner/repo', githubRepo: { owner: 'owner', repo: 'repo' } }] };
  }, 'owner/repo');
  assert.equal(source, 'sources/github/owner/repo');
  assert.ok(calls[1].endsWith('pageToken=page%2F2'));
});

test('failed provider session fails loudly after reporting session identity', async () => {
  const { args, state } = fixture(); const original = args.jules; const reports = [];
  args.jules = async (path, method) => path.startsWith('sessions/') ? { state: 'FAILED' } : original(path, method);
  await assert.rejects(repair({ ...args, report: value => reports.push(value) }), /Jules session failed/);
  assert.equal(reports[0].session, 'sessions/123');
  assert.equal(reports.at(-1).state, 'FAILED');
  assert.equal(state.checks.length, 1);
});

test('missing key and unmatched source fail before attempt reservation', async () => {
  const { args, state } = fixture();
  await assert.rejects(repair({ ...args, hasKey: false }), /Missing JULES_API_KEY/);
  await assert.rejects(repair({ ...args, jules: async () => ({ sources: [] }) }), /not connected/);
  assert.equal(state.checks.length, 0);
});

test('marker creation failure prevents the session POST', async () => {
  const { args, state } = fixture(); const original = args.gh;
  args.gh = (...call) => call[1] === 'POST' ? Promise.reject(new Error('marker refused')) : original(...call);
  await assert.rejects(repair(args), /marker refused/);
  assert.equal(state.calls.filter(c => c.service && c.method === 'POST').length, 0);
});
