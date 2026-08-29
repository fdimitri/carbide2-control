# JWT claims — control plane → workspace

This file documents the contract between [carbide2-control](https://github.com/fdimitri/carbide2-control)
(JWT issuer) and [carbide2-server](https://github.com/fdimitri/carbide2-server)
(JWT verifier). A copy of this file lives in **both** repos; keep them in sync
by hand. Any change to claim names, types, or validation rules is a breaking
wire-format change.

## Algorithm

`RS256` (RSA 2048+, asymmetric). Control holds the PRIVATE signing key; pods
verify with the PUBLIC key published at `/.well-known/jwks.json`. The token
header carries a `kid` — a stable fingerprint of the public key (base64url
SHA-256 of the DER SPKI), never a counter — that names which JWKS entry
signed it. The verifier pins `RS256`; it never selects the algorithm from the
token's own `alg` claim (no alg-confusion).

## Required claims

| Claim        | Type    | Example                  | Notes                                                     |
| ------------ | ------- | ------------------------ | --------------------------------------------------------- |
| `iss`        | string  | `carbide-control`        | Constant. Workspace rejects tokens with any other issuer. |
| `exp`        | integer | `1733184000`             | Unix seconds. Recommended TTL: 5 minutes.                 |
| `iat`        | integer | `1733183700`             | Unix seconds.                                             |
| `user_email` | string  | `alice@example.com`      | Denormalized for display + audit.                         |
| `user_uuid`  | string  | `<uuid>`                 | Stable control-side user identity.                        |
| `workspace_uuid` | string | `<uuid>`              | Stable control-side workspace identity.                   |
| `project_uuid`   | string | `<uuid>`              | Stable control-side project identity (== workspace_uuid under 1:1). |
| `scope`      | string  | `workspace:rw` / `workspace:api` | `workspace:rw` authorizes the worker WS; `workspace:api` authorizes the workspace REST API. Scope selects the token's TTL. |

No integer claims (`sub`/`aud`/`user_id`/`project_id`). Identity is uuid-only.


## Validation rules (workspace side)

The workspace verifies, in order:

1. Signature valid against the JWKS public key named by the token's `kid`.
2. `iss == "carbide-control"`.
3. `exp > now`.
4. `scope` is in the allowlist `[workspace:rw, workspace:api]`.

Failing any check returns 401 from the WS upgrade and the connection is closed
before any worker command is processed.

## Future claims (reserved)

- `agent_id` — when an agent (not a human) is connecting on the user's behalf.
- `terminal_ids` — allowlist of terminal IDs the agent may attach to.
- `expires_after_idle` — kill the WS if no traffic for N seconds.

Do not add new required claims without bumping a version field, which would
also need to be a required claim. For now we accept that any breaking change
requires lockstep deployment of both repos.
