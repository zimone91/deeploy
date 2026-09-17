// DeePloy — the zim.one/deeploy endpoint.
//
// The worker holds NO install logic. It fetches get-deeploy.sh from the
// repository at the tag named in the path and prepends exactly one line that
// pins the version. That is the whole design: the one-liner and the paranoid
// path (read the file, then run it) serve the SAME bytes, so the README's
// promise that they are the same file is a property of the system rather than
// a claim someone has to trust.
//
//   /deeploy                -> DEFAULT_TAG
//   /deeploy/v0.1.0-rc6     -> that tag
//   anything else           -> 400, and the body is inert (see below)
//
// The file is .mjs, not .js, so `node` can import it without depending on
// module-syntax detection. That is what lets CI determine the default tag by
// RUNNING this worker instead of grepping it — see the gate in ci.yml.
//
// Deploy:  npx wrangler deploy

// Bumped on every release. A stale value makes the bare /deeploy path serve an
// old version silently and indefinitely. Exported because the release gate
// imports this module and exercises it; a gate that parsed the text of this
// line could be defeated by anything after the literal.
export const DEFAULT_TAG = 'v0.1.0-rc6'

const REPO = 'zimone91/deeploy'
const FILE = 'get-deeploy.sh'

// The route pattern is `zim.one/deeploy*`, and that trailing `*` is a glob, not
// a path-segment boundary: /deeploything reaches this worker too. This anchored
// match is what makes the segment boundary real.
const PATH_RE = /^\/deeploy(?:\/(.*))?$/

// A tag from the path is interpolated into a line that sh will execute. This
// regex is the only thing standing between a URL and a shell, so it is a
// whitelist: no slash, no quote, no space, no percent-encoding.
const TAG_RE = /^v[0-9A-Za-z.\-_]{1,40}$/

// Error bodies begin with '#' on purpose. A caller who drops curl's -f pipes
// this straight into `sh -c "$(...)"`; as a comment it executes as nothing.
const refuse = (status, message) =>
    new Response(`# ${message}\n`, {
        status,
        headers: {
            'content-type': 'text/plain; charset=utf-8',
            'x-content-type-options': 'nosniff',
            'cache-control': 'no-store',
        },
    })

export default {
    async fetch(request) {
        const url = new URL(request.url)

        // A route pattern with no scheme matches http:// as well as https://,
        // and this zone does not force HTTPS (measured: http://zim.one/deeploy
        // answers 404 in cleartext, it does not redirect). Serving a script
        // that runs as root over cleartext is not acceptable, so redirect
        // rather than answer. Pinning the route to https:// instead would leave
        // port 80 answering from whatever else is on the zone; this way the
        // worker owns both and `curl -L` still works.
        if (url.protocol !== 'https:') {
            url.protocol = 'https:'
            return Response.redirect(url.toString(), 301)
        }

        if (request.method !== 'GET' && request.method !== 'HEAD') {
            return refuse(405, `method ${request.method} not allowed — this endpoint serves a shell script over GET`)
        }

        const m = PATH_RE.exec(url.pathname)
        if (m === null) {
            return refuse(400, `no such path: ${JSON.stringify(url.pathname)}`)
        }

        // undefined for /deeploy, '' for /deeploy/ — both mean "the default".
        const raw = m[1]
        const tag = raw === undefined || raw === '' ? DEFAULT_TAG : raw

        if (!TAG_RE.test(tag)) {
            return refuse(400, `not a valid DeePloy tag: ${JSON.stringify(tag)} — expected something like v0.1.0-rc6`)
        }

        const upstream = `https://raw.githubusercontent.com/${REPO}/${tag}/${FILE}`
        let bytes
        try {
            const res = await fetch(upstream, { headers: { 'user-agent': 'deeploy-get-worker' } })
            if (!res.ok) {
                // Fail closed: no fallback to the default tag, no cached copy. A
                // tag that does not exist must not quietly install a different one.
                return refuse(res.status === 404 ? 404 : 502, `no ${FILE} at ${tag} (upstream ${res.status})`)
            }
            // The body is read INSIDE the try: fetch() resolves when the headers
            // arrive, so an upstream that dies mid-body rejects here, not there.
            // Outside, that rejection would escape and the worker would return
            // no response at all — the one outcome refuse() exists to prevent.
            bytes = new Uint8Array(await res.arrayBuffer())
        } catch {
            return refuse(502, `could not read ${FILE} at ${tag} from the repository`)
        }

        // Bytes, not text. `res.text()` is a UTF-8 decode: it strips a leading
        // BOM and replaces every invalid byte with U+FFFD, silently, with a 200.
        // This body is piped into a shell, and the promise that it equals the
        // file on GitHub from line 2 onward has to hold for every possible file,
        // not just for files that happen to be valid UTF-8 today.
        const prefix = new TextEncoder().encode(`DEEPLOY_INSTALL_TAG='${tag}'\n`)
        const out = new Uint8Array(prefix.length + bytes.length)
        out.set(prefix, 0)
        out.set(bytes, prefix.length)

        return new Response(request.method === 'HEAD' ? null : out, {
            status: 200,
            headers: {
                'content-type': 'text/plain; charset=utf-8',
                'x-content-type-options': 'nosniff',
                // Set explicitly so HEAD reports it too: the one honest use of
                // HEAD here is asking how many bytes are about to reach a root
                // shell, and that answer must not depend on the method.
                'content-length': String(out.length),
                // Five minutes: a new release propagates quickly, and a burst
                // does not turn into one upstream request per client.
                'cache-control': 'public, max-age=300',
                'x-deeploy-tag': tag,
            },
        })
    },
}
