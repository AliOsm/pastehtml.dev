<p align="center">
  <a href="https://pastehtml.dev">
    <img src="public/og-image.png" alt="pastehtml.dev — Share HTML in seconds" width="640">
  </a>
</p>

# pastehtml.dev

Share HTML pages in seconds. Drop an HTML file, get a private link your friends
can open, preview, and view the source of. Anonymous publishing still works,
and accounts add folders, custom subdomains, view counts, browser-based re-upload
updates, and account API keys for agent publishing into folders.

## How it works

- Drag and drop (or browse for) an `.html`/`.htm` file up to 2 MB.
- The document is published at `https://<token>.pastehtml.dev/` — or at a
  claimed custom subdomain like `https://launch-plan.pastehtml.dev/` — with an
  inspector page (copy link, preview, highlighted source) at `/p/<token>`.
  Tokens are random 32-character lowercase-alphanumeric IDs (~165 bits of
  entropy — lowercase because they double as subdomains, and browsers lowercase
  hostnames), so random links are private unless shared.
- Pastes can be password-protected. Locked pastes require the password before
  the inspector page, raw bytes, rendered preview, or live subdomain are served.
- Signed-in users can save pastes into folders, see view counts, and re-upload a
  replacement `.html`/`.htm` file without changing the share link. Pastes can
  never be deleted. API-created update tokens still work for token-based
  automated updates.
- The share page offers a live preview (with an in-site fullscreen mode) and
  a Rouge-highlighted source view.
- Every paste is served as a real page from its own origin —
  `https://<token>.pastehtml.dev/` — so scripts and localStorage work
  (review-progress checklists persist) while staying fully isolated from
  other pastes and from the app itself. The path-based `/p/<token>/raw`
  endpoint returns the paste's exact bytes as `text/plain` — a byte-exact copy
  for programmatic clients, immune to any CDN HTML rewriting in transit — while
  `/p/<token>/render` serves the same bytes as `text/html` inside a CSP `sandbox`.

## Agent API

Publish without a browser — ideal for AI agents that produce design documents
or implementation plans and want to hand back a share link. Anonymous publishing
still works with no credentials; signed-in users can also create account API keys
at `/api_keys` so an agent can publish into their account and target folders.

```bash
# Multipart upload
curl -F "file=@plan.html" https://pastehtml.dev/api/pastes

# Or stream the HTML straight from a pipe
curl --data-binary @plan.html -H "Content-Type: text/html" \
  "https://pastehtml.dev/api/pastes?filename=plan.html"
```

Anonymous creation returns `201` with
`{ token, title, custom_subdomain, folder, owner, account_paste, password_protected, views_count, live_url, url, raw_url, render_url, markdown_url, update_token }`
(or `422` with `{ errors }`). Account-key creation returns the same paste fields
but omits `update_token`; update account-owned pastes with the account key so
revoking the key stops that agent's future access. Add `password=<secret>` (or
`custom_subdomain=<name>`, which requires an account key) to creation/update
requests; send `clear_password=1` on updates to remove a paste password. Fetch `raw_url` to read a paste's exact bytes
back (`text/plain`, never rewritten in transit).

### Account API keys for agents

A signed-in user can open **API keys** from the dashboard, create a key, and give
that secret to an agent. Use it as either `Authorization: Bearer pht_...` or
`X-PasteHTML-API-Key: pht_...`. When a valid account key is present on
`POST /api/pastes`, the paste is owned by that user and appears in their
dashboard. Folder targeting is account-only:

```bash
curl -H "Authorization: Bearer $PASTEHTML_API_KEY" \
  --data-binary @plan.html -H "Content-Type: text/html" \
  "https://pastehtml.dev/api/pastes?filename=plan.html&folder_name=Roadmap"
```

Use `folder_name=<name>` to find or create a folder under that account,
`folder_id=<id>` to target an existing folder, and `clear_folder=1` on updates
to move a paste back to All pastes. Keys can also be scoped to a default folder
when created; scoped keys always publish there, can update only pastes already
in that folder, reject folder overrides, only list that folder through the folder
API, and cannot create unrelated folders. Scoped keys are revoked automatically
if the folder is deleted. Unscoped agents can discover existing folder IDs with:

```bash
curl -H "Authorization: Bearer $PASTEHTML_API_KEY" \
  https://pastehtml.dev/api/folders
```

Unscoped keys can create folders with either nested form params
(`folder[name]=Roadmap`) or a simple top-level `name=Roadmap`, whichever is
easier for the client. Folder-scoped keys receive `403` on folder creation.

An account key can update pastes owned by that account, while the per-paste
`update_token` flow keeps working as long as the paste stays anonymous. If an
agent needs to claim an anonymous paste into an account, send the account key in
`Authorization: Bearer ...` and the paste secret separately as
`X-Update-Token: ...`. Claiming is one-way: afterward the account key is the
paste's update credential and the old token stops working.

The `update_token` is revealed exactly once — the server stores only a digest —
and authorizes any number of in-place updates while the paste remains anonymous:

```bash
curl -X PATCH -H "Authorization: Bearer $UPDATE_TOKEN" \
  -F "file=@plan.html" https://pastehtml.dev/api/pastes/$TOKEN
```

Updates accept the same two body forms as creation and return `200` with the
refreshed `{ token, title, custom_subdomain, folder, owner, account_paste, password_protected, views_count, live_url, url, raw_url, render_url, markdown_url }`,
`403` for a wrong or missing update token or an account key that does not own the paste,
and `404` for an unknown paste. Paste publish/update endpoints are rate limited per IP at 20 requests per minute and 1,000 per day; folder API endpoints also require an account key and are rate limited per IP.

Agents discover all of this on their own: the full integration guide lives at
[`/llms.txt`](https://pastehtml.dev/llms.txt) (also pointed to from the
homepage, both visibly and in an HTML comment for raw fetchers). Telling an
agent "publish this on pastehtml.dev" is enough.

## MCP server

For agents that speak the [Model Context Protocol](https://modelcontextprotocol.io),
pastehtml.dev is also a remote MCP server at `https://pastehtml.dev/mcp`
(Streamable HTTP). Instead of a `pht_` key, the agent authorizes once through
your browser over OAuth and then works inside your account — the same folders,
view counts, and permanent pastes as the dashboard.

```bash
# Claude Code
claude mcp add --transport http pastehtml https://pastehtml.dev/mcp

# Codex
codex mcp add pastehtml --url https://pastehtml.dev/mcp
```

On first use the client opens a browser consent screen; approve it and the
agent is connected — no key to copy or store. Authorization is OAuth 2.1 with
PKCE and RFC 7591 Dynamic Client Registration, scoped to `mcp:read` and
`mcp:write`. Review or revoke connected agents any time under **Connected
agents** in the dashboard.

Ten tools are exposed (pastes are permanent — there is no delete-paste tool):

- `create_paste` — publish a new HTML or Markdown paste, optionally into a folder.
- `update_paste` — republish an existing paste's content (overwrites it in place).
- `configure_paste` — change a paste's password, custom subdomain, or folder.
- `get_paste` — fetch one paste's metadata, URLs, and stored content.
- `get_paste_stats` — aggregate view analytics for a paste.
- `list_pastes` — page through the account's pastes, optionally filtered by folder.
- `list_folders` — list folders with their paste counts.
- `create_folder` — create a new, empty folder.
- `rename_folder` — rename a folder.
- `delete_folder` — delete a folder (its pastes survive, unfiled).

Dynamic Client Registration can be switched off in production with the
`MCP_DYNAMIC_REGISTRATION_DISABLED` environment variable (any already
pre-registered clients keep working). Smoke-test a deployment by fetching its
discovery document:

```bash
curl https://pastehtml.dev/.well-known/oauth-protected-resource
```

## Stack

- Ruby on Rails 8.1 · PostgreSQL · Hotwire (Turbo + Stimulus)
- Tailwind CSS v4 (cssbundling) · esbuild (jsbundling) · Yarn 4
- Tooling via [mise](https://mise.jdx.dev), PostgreSQL via Docker Compose
- Comic-book design: Bangers display type over Inter, halftone textures,
  ink-outlined panels with hard offset shadows
- Installable PWA: manifest + minimal network-first service worker with an
  offline fallback page (pastes themselves are never cached)
- SEO via meta-tags (OG/Twitter cards with a branded OG image, canonical,
  noindex on paste pages) and comic-styled static error pages

## Development

```bash
mise run dev        # starts postgres (docker), installs deps, prepares db, runs bin/dev
```

Or step by step:

```bash
mise run docker:start   # postgres on localhost:5435
mise run deps           # bundle install + yarn install
mise run db:prepare
bin/dev                 # rails server + js/css watchers on port 3000
```

## Tests and lint

```bash
mise run test   # rails test
mise run lint   # rubocop + brakeman
```

## Deployment

Deploys with [Kamal](https://kamal-deploy.org) from GitHub Actions (the
"Kamal Run" workflow) to a single server: the app container plus a postgres
18 accessory. `db/production.sql` creates the Solid Cache/Queue databases on
the accessory's first boot. Pastes are served from `<token>.pastehtml.dev`
subdomains, so the proxy routes the wildcard with a Cloudflare Origin CA
certificate (wildcards can't get Let's Encrypt certs over HTTP-01).

One-time setup:

1. **Cloudflare** (free plan): add a proxied `A` record for `pastehtml.dev`,
   `www`, and a proxied wildcard `*` record, all pointing at the server.
   Set SSL/TLS mode to **Full (strict)**. Create an Origin Server
   certificate for `pastehtml.dev, *.pastehtml.dev` and keep the PEM pair.
2. **Repository Actions secrets**: `SERVER_IP`, `SSH_PRIVATE_KEY` (root
   access to the server), `RAILS_MASTER_KEY` (from `config/master.key`),
   `POSTGRES_PASSWORD`, `CLOUDFLARE_ORIGIN_CERTIFICATE` and
   `CLOUDFLARE_ORIGIN_KEY` (the Origin CA PEM pair). The container registry
   (ghcr.io) authenticates with the workflow's own `GITHUB_TOKEN`.
3. Run the **Kamal Run** workflow with the command `setup` once (provisions
   postgres + proxy), then with `deploy` for every release.

For local runs of kamal commands, put the Origin CA pair in
`.kamal/certs/origin.pem` / `origin-key.pem` (gitignored), export
`SERVER_IP` and `POSTGRES_PASSWORD`, and remove the GHA builder cache block
from `config/deploy.yml` if you need to build the image locally.
