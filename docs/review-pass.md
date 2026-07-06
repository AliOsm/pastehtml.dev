# Review pass notes

This pass adds account API keys for trusted agents and records the hardening work from the implementation reviews.

## Account API keys

- Signed-in users can create and revoke API keys from `/api_keys`.
- Keys are shown once, stored only as an HMAC digest, and displayed later only by prefix.
- Keys may be unscoped or scoped to a default folder.
- Agents send keys as `Authorization: Bearer pht_...`, `X-PasteHTML-API-Key`, or `X-API-Key`.
- `POST /api/pastes` with a valid account key saves the paste under that user.
- Unscoped keys may route a paste with `folder_id` or `folder_name`; `folder_name` finds or creates the folder.
- Folder-scoped keys always publish into their scoped folder, can update only pastes already in that folder, reject folder overrides, list only their scoped folder through `GET /api/folders`, and cannot create unrelated folders.
- Scoped keys are revoked automatically if their folder is deleted.
- Account-key publishes intentionally omit the anonymous `update_token`; the account key is the continuing update credential.
- `GET /api/folders` and `POST /api/folders` let unscoped agents discover/create account folders.

## Update behavior

- Anonymous publishing still returns a one-time `update_token` as before.
- `PATCH /api/pastes/:token` accepts either the per-paste update token or an account key that owns the paste.
- If an agent needs to claim an anonymous paste into the account, it can send the account key in `Authorization` and the paste secret in `X-Update-Token`.
- Option-only API updates are supported, so agents can change subdomain/password/folder without re-uploading content.

## Review fixes

- Password-protected inspector previews embed the live paste with a short-lived signed preview token instead of depending on cross-origin session cookies.
- Preview tokens and password-unlock sessions include the paste update version, so re-uploading a file or changing options invalidates older access grants.
- Custom token generation avoids both existing tokens and existing custom subdomains.
- Persistent login uses a host-prefixed production cookie name and relative GET-only return paths, which reduces subdomain cookie-tossing/open-redirect risk from user-controlled paste origins.
- API raw-body publishing reads at most `Paste::MAX_CONTENT_BYTES + 1` bytes before validation instead of materializing an unbounded request body.
- One-time API-key reveal pages send `Cache-Control: no-store` and Turbo no-cache metadata so full secrets are not cached by browser/Turbo page snapshots.
- API folder discovery/creation, password unlock, sign-in, and sign-up attempts have focused rate limits.
- Destructive-protection callbacks run before association-dependent callbacks, preventing failed paste/folder destroys from deleting child view records or widening scoped keys.
- API paste option assignment and persistence run in a database transaction so failed publishes/updates do not leave behind newly-created `folder_name` folders.
- `folder_id` API parameters use strict numeric parsing, so malformed IDs such as `1abc` are rejected.
- `POST /api/folders` accepts either `folder[name]=...` or top-level `name=...`.
- Filenames, user emails, and passwords have model-level length validation before database/bcrypt limits are reached; password checks use bcrypt's byte limit and avoid hashing over-limit values before validation.
- API keys/folders are localized in English and Arabic; locale keys/placeholders were checked for parity and duplicate keys.
- The prebuilt CSS includes the new account API key page utility classes for environments that do not rebuild Tailwind during review.
- Regression tests cover key generation/authentication, scoped folders, account publishing/updating, folder discovery/creation, anonymous-claim updates, callback ordering, transactional folder creation, malformed folder IDs, password-preview/session invalidation, and length validations.

## Second review pass (deep multi-agent + Rails-generator + frontend audit)

A follow-up review compared the auth code against the Rails 8.1 authentication generator,
audited the frontend against the Web Interface Guidelines, and ran an adversarially-verified
multi-dimension pass. Brakeman stays at 0 warnings and i18n EN/AR parity is exact.

Fixes applied:

- Every successful redirect after a non-GET action now returns `303 See Other` (sign-out,
  sign-in, sign-up, folder/paste create+update, folder/api-key/paste destroy). A `DELETE`/`PATCH`
  answered with `302` makes the browser re-issue the same method to a GET-only path (Fetch
  standard), so Turbo sign-out previously landed on a routing error.
- Sign-in uses `User.authenticate_by` (the generator idiom), which runs a dummy password digest even for
  unknown emails, closing the user-enumeration timing side-channel that `find_by(email)&.authenticate` left
  open by returning immediately when no record matched.
- Once a paste is claimed into an account, a previously revealed anonymous `update_token` stops
  working (`Paste#updatable_with?` now requires `user_id` to be blank); the account credential is
  the sole update path afterward.
- `parse_folder_id` parses base 10 explicitly, so a zero-padded id like `010` is no longer read as
  octal 8 and filed into the wrong folder.
- Concurrent `folder_name` auto-creation is race-safe: the insert runs in a savepoint and a lost
  race reuses the winning row instead of surfacing a 500.
- Authenticated write endpoints are rate limited: `api_keys#create` (20/hour) and
  `folders#create` / UI `pastes#update` (30/minute), keyed per user.
- The locale cookie is `__Host-`-prefixed in production, closing the last cookie a paste subdomain
  could shadow (mirrors the auth cookie's hardening).
- The dashboard/folder listings project `octet_length(content)` instead of loading every paste's
  full (up to 2 MB) body just to render a byte-size label.
- Accessibility: skip-to-content link, `<main id>` target, the header logo's visible text is now its
  accessible name (WCAG 2.5.3), a visible focus ring on the custom-subdomain composite input, and an
  accessible name on the one-time API-key reveal field (WCAG 4.1.2).

Regression tests added: sign-in success/failure/unknown-email, sign-out (session destroyed, `303`),
session-fixation reset on login, web-`FoldersController` auth + cross-user IDOR (show/edit/update/destroy),
cross-user paste edit/update (`require_owner!`), cross-user API-key revoke, the API `folder_id`/`folder_name`
cross-user and mismatch branches, scoped-key positive folder enforcement + `clear_folder` rejection,
leaked-token-after-claim rejection, the password gate on raw/render/markdown, `custom_subdomain`
taken/token-collision, and case-insensitive email uniqueness. A `bob` user/folder/api-key fixture backs the
cross-user cases. (Rate-limit thresholds are intentionally not unit-tested: the test cache is `:null_store`
and a shared real store would cross-throttle the parallel suite.)

## Final adversarial review pass

A last multi-lens review (correctness, tests, idiom, security, docs) hardened the loose ends:

- **Custom subdomains now require an account API key.** `Api::PastesController#apply_options` previously let
  anonymous callers set `custom_subdomain`, so anyone could permanently squat a memorable origin
  (`paypal-login.pastehtml.dev`) since pastes are never deletable. It is now gated like folders (401
  `custom_subdomain requires an account API key`), matching the browser UI. Anonymous `password=` stays
  allowed (the paste creator's own choice, paired with the update token). README/llms.txt updated to match.
- `status: :see_other` extended to the remaining non-GET redirects for a uniform 303 convention:
  `paste_passwords#create`, the `require_owner!` guard, and `pastes#create` failures.
- Removed a dead, unreachable branch in `PastesController#assign_folder` (its caller returns early unless
  authenticated).
- The locale cookie read falls back to the legacy unprefixed name so the one-time `__Host-` rename doesn't
  drop existing users' saved language.
- The "destroy protection runs before dependent view cleanup" model test was tautological (a rolled-back
  DELETE still satisfied the count assertion); it now asserts no `paste_views` DELETE SQL is emitted, which
  only the prepended callback guarantees — verified to fail if `prepend: true` is removed.
- Doc accuracy: README response lists include `markdown_url`; the `authenticate_by` note no longer inverts
  its own security rationale; the intro no longer implies password protection is account-only.
- `Authentication#request_authentication` redirects unauthenticated requests with `303 See Other`, so an
  unauthenticated `PATCH`/`DELETE` to a protected route (folders, api keys, sign-out, owned paste update)
  follows to sign-in as a `GET` instead of replaying the verb against the `GET`-only `/session/new`; a
  `folders_controller_test` case asserts the 303 on unauthenticated `PATCH`/`DELETE`.
- The "update_token is valid forever" overstatement was corrected everywhere it appeared (README, llms.txt,
  the `Api::PastesController` header comment, and the home-page agent comment): the token is valid only while
  the paste stays anonymous, and claiming the paste into an account retires it (matching `Paste#updatable_with?`).
