#!/usr/bin/env bash
# Tests for worker/index.mjs — no network.
#
# The worker is JavaScript, so this suite shells out to node. There is no
# skip path: node is already required in CI by the release gate that runs the
# worker to read its default tag, so a box that cannot run node cannot verify
# a release either. A check that cannot determine the answer does not get to
# report success — the same rule that removed the checksum bypass.
#
# The upstream is stubbed, so every scenario is a statement about this worker
# and never about GitHub.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORKER="$ROOT/worker/index.mjs"

if ! command -v node >/dev/null 2>&1; then
    echo "  FAIL node is not on PATH, and worker/index.mjs cannot be tested without it"
    echo "       CI needs node anyway: the release gate imports this worker to read"
    echo "       the tag it serves. Install node rather than skipping this suite."
    echo "RESULT: 0 passed, 1 failed"
    exit 1
fi
if [[ ! -f "$WORKER" ]]; then
    echo "  FAIL ${WORKER} does not exist"
    echo "RESULT: 0 passed, 1 failed"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/probe.mjs" <<'PROBE_JS'
const WORKER = process.argv[2]
const worker = (await import(WORKER)).default

// The upstream, entirely under test control. `bytes` is what raw.github would
// return; the scenarios below change it to things a real file could be.
let lastUrl = null
let up = { ok: true, status: 200, bytes: Buffer.from("#!/bin/sh\nreal body\n") }
globalThis.fetch = async (u) => {
    lastUrl = u
    if (up.throws) throw new Error('connection reset')
    return {
        ok: up.ok,
        status: up.status,
        arrayBuffer: async () => {
            if (up.bodyThrows) throw new Error('truncated mid-body')
            return up.bytes
        },
    }
}

// console.error is this worker's only diagnostic channel once it is live —
// `wrangler tail` and nothing else. Capture it so "it logs the reason" can be
// asserted instead of hoped for.
let logged = []
console.error = (...args) => { logged.push(args.join(' ')) }

let pass = 0, fail = 0
const check = (name, actual, expected) => {
    const a = JSON.stringify(actual), e = JSON.stringify(expected)
    if (a === e) { pass++; console.log(`  ok   ${name}`) }
    else { fail++; console.log(`  FAIL ${name}\n     expected: ${e}\n     actual:   ${a}`) }
}
const hit = async (path, { method = 'GET', scheme = 'https' } = {}) => {
    lastUrl = null
    const r = await worker.fetch(new Request(`${scheme}://zim.one${path}`, { method }))
    const buf = Buffer.from(await r.arrayBuffer())
    return {
        status: r.status, buf, text: buf.toString('utf8'), upstream: lastUrl,
        location: r.headers.get('location'), length: r.headers.get('content-length'),
        tag: r.headers.get('x-deeploy-tag'), cache: r.headers.get('cache-control'),
    }
}

console.log('== the two paths a user is told to use ==')
let r = await hit('/deeploy')
check('bare /deeploy -> 200', r.status, 200)
check('  first line pins the default tag', r.text.split('\n')[0], "DEEPLOY_INSTALL_TAG='v0.1.0-rc6'")
check('  fetches that tag from the repository', r.upstream,
      'https://raw.githubusercontent.com/zimone91/deeploy/v0.1.0-rc6/get-deeploy.sh')
r = await hit('/deeploy/v0.1.0-rc6')
check('pinned path -> 200', r.status, 200)
check('  and reports the tag it served', r.tag, 'v0.1.0-rc6')
check('trailing slash means the default', (await hit('/deeploy/')).status, 200)

console.log('== the route glob is not a path-segment boundary ==')
// `zim.one/deeploy*` delivers all of these to the worker; the route cannot
// express a segment boundary, so the worker has to.
for (const p of ['/deeploything', '/deeployer', '/deeploy-x', '/deeployv1', '/deeploy.sh']) {
    r = await hit(p)
    check(`${p} -> 400`, r.status, 400)
    check('  and nothing is fetched', r.upstream, null)
}

console.log('== the tag reaches a line that sh executes, so it is a whitelist ==')
for (const p of ['/deeploy/;whoami', "/deeploy/v1';id;'", '/deeploy/$(id)', '/deeploy/v1 x',
                 '/deeploy/main', '/deeploy/v1/extra', '/deeploy/%76%31', '/deeploy/v1%0Aid',
                 '/deeploy/../etc/passwd', '/deeploy/v1`id`', '/deeploy/"', "/deeploy/'"]) {
    r = await hit(p)
    check(`${p} -> 400`, r.status, 400)
    check('  and nothing is fetched', r.upstream, null)
}
check('40 characters after v are allowed', (await hit('/deeploy/v' + 'a'.repeat(40))).status, 200)
check('41 are not', (await hit('/deeploy/v' + 'a'.repeat(41))).status, 400)
check('a bare "v" is not a tag', (await hit('/deeploy/v')).status, 400)

console.log('== refusal bodies are inert shell ==')
// A caller who drops curl's -f pipes the error body into sh.
for (const p of ['/deeploything', '/deeploy/;whoami']) {
    r = await hit(p)
    check(`${p} body is nothing but comments`,
          r.text.split('\n').every(l => l === '' || l.startsWith('#')), true)
    check('  and is not cached', r.cache, 'no-store')
}
check('POST -> 405', (await hit('/deeploy', { method: 'POST' })).status, 405)

console.log('== cleartext is redirected, not answered ==')
r = await hit('/deeploy', { scheme: 'http' })
check('http -> 301', r.status, 301)
check('  to the same URL over https', r.location, 'https://zim.one/deeploy')
check('  without fetching anything', r.upstream, null)
check('http on a pinned path keeps the path',
      (await hit('/deeploy/v0.1.0-rc6', { scheme: 'http' })).location,
      'https://zim.one/deeploy/v0.1.0-rc6')
// The redirect happens after the path and the tag are found good, so junk is
// refused on the first trip instead of being sent away and refused on the
// second, and nothing unvalidated is echoed back in a Location header.
r = await hit('/deeploy/;whoami', { scheme: 'http' })
check('http with a junk path -> 400 on the first trip', r.status, 400)
check('  and no Location handing the junk back', r.location, null)
r = await hit('/deeploything', { scheme: 'http' })
check('http outside the path segment -> 400, not 301', r.status, 400)

console.log('== the body is copied as bytes, which is what makes it the same file ==')
// res.text() would strip a BOM and turn any invalid byte into U+FFFD, silently.
const bodies = {
    'plain ascii':        Buffer.from('#!/bin/sh\nx\n'),
    'utf-8 multibyte':    Buffer.from('#!/bin/sh\n· banner\n'),
    'utf-8 BOM':          Buffer.concat([Buffer.from([0xEF, 0xBB, 0xBF]), Buffer.from('#!/bin/sh\n')]),
    'an invalid byte':    Buffer.from([0x23, 0x80, 0x0A]),
    'CRLF':               Buffer.from('#!/bin/sh\r\nx\r\n'),
    'no trailing newline':Buffer.from('#!/bin/sh\nx'),
    'an embedded NUL':    Buffer.from([0x23, 0x00, 0x0A]),
    'empty':              Buffer.alloc(0),
    '1 MiB':              Buffer.alloc(1024 * 1024, 0x41),
}
for (const [name, bytes] of Object.entries(bodies)) {
    up = { ok: true, status: 200, bytes }
    r = await hit('/deeploy')
    const served = r.buf.subarray(r.buf.indexOf(0x0A) + 1)
    check(`tail -n +2 is byte-identical: ${name}`, served.equals(bytes), true)
    check('  and content-length is the real length', Number(r.length), r.buf.length)
}
up = { ok: true, status: 200, bytes: Buffer.from('#!/bin/sh\nx\n') }
check('exactly one line is prepended',
      (await hit('/deeploy')).text.split('\n').length - '#!/bin/sh\nx\n'.split('\n').length, 1)

console.log('== every failure fails closed ==')
up = { ok: false, status: 404 }
r = await hit('/deeploy/v9.9.9')
check('a tag with no file -> 404', r.status, 404)
check('  and does NOT fall back to the default', r.text.includes('v0.1.0-rc6'), false)
up = { ok: false, status: 500 }
check('upstream 500 -> 502', (await hit('/deeploy')).status, 502)
up = { throws: true }
check('upstream unreachable -> 502', (await hit('/deeploy')).status, 502)
up = { ok: true, status: 200, bodyThrows: true }
r = await hit('/deeploy')
// fetch() resolves on headers; a body that dies afterwards rejects at the read.
check('a body that dies mid-read -> 502, not an empty response', r.status, 502)
check('  and that refusal is inert too', r.text.startsWith('#'), true)

console.log('== a 502 leaves a trace; an ordinary 404 does not ==')
// A 502 with nothing behind it is a 502 debugged by guesswork. A wrong tag is
// not an incident, so the difference has to be asserted in both directions.
up = { throws: true }
logged = []
r = await hit('/deeploy')
check('unreachable upstream -> 502', r.status, 502)
check('  and the reason reaches the log', logged.filter(l => l.includes('v0.1.0-rc6')).length, 1)
up = { ok: true, status: 200, bodyThrows: true }
logged = []
r = await hit('/deeploy')
check('a body that dies mid-read -> 502', r.status, 502)
check('  and names what went wrong', logged.filter(l => l.includes('truncated')).length, 1)
up = { ok: false, status: 500 }
logged = []
r = await hit('/deeploy')
check('upstream 500 -> 502', r.status, 502)
check('  and the status reaches the log', logged.filter(l => l.includes('500')).length, 1)
up = { ok: false, status: 404 }
logged = []
r = await hit('/deeploy/v9.9.9')
check('a tag that does not exist -> 404', r.status, 404)
check('  and is NOT logged as an incident', logged.length, 0)

console.log('== HEAD ==')
up = { ok: true, status: 200, bytes: Buffer.from('#!/bin/sh\nx\n') }
r = await hit('/deeploy', { method: 'HEAD' })
check('HEAD -> 200 with no body', [r.status, r.buf.length], [200, 0])
check('  but the same content-length a GET would report',
      Number(r.length), 12 + "DEEPLOY_INSTALL_TAG='v0.1.0-rc6'\n".length)

console.log('')
console.log('===================================')
console.log(`RESULT: ${pass} passed, ${fail} failed`)
console.log('===================================')
process.exit(fail === 0 ? 0 : 1)
PROBE_JS

node "$TMP/probe.mjs" "$WORKER"
