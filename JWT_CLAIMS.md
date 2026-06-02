# JWT claims — control plane → workspace

This file documents the contract between [carbide2-control](https://github.com/fdimitri/carbide2-control)
(JWT issuer) and [carbide2-server](https://github.com/fdimitri/carbide2-server)
(JWT verifier). A copy of this file lives in **both** repos; keep them in sync
by hand. Any change to claim names, types, or validation rules is a breaking
wire-format change.

## Algorithm

`HS256` against a shared secret stored in the Kubernetes Secret `workspace-jwt`.
The operator mirrors this secret into every `ws-N` namespace at provision time
so the workspace pod can verify tokens minted by the control plane.

## Required claims

| Claim        | Type    | Example                  | Notes                                                     |
| ------------ | ------- | ------------------------ | --------------------------------------------------------- |
| `iss`        | string  | `carbide-control`        | Constant. Workspace rejects tokens with any other issuer. |
| `sub`        | string  | `user:42`                | `user:<control_plane_user_id>`.                           |
| `aud`        | string  | `workspace:42`           | `workspace:<project_id>`. Workspace rejects mismatch.     |
| `exp`        | integer | `1733184000`             | Unix seconds. Recommended TTL: 5 minutes.                 |
| `iat`        | integer | `1733183700`             | Unix seconds.                                             |
| `user_id`    | integer | `42`                     | Control-plane DB primary key. Workspace uses for denormalized membership cache. |
| `user_email` | string  | `alice@example.com`      | Denormalized for display + audit.                         |
| `project_id` | integer | `42`                     | Must match `aud` suffix and the workspace pod's `WORKSPACE_PROJECT_ID` env. |
| `scope`      | string  | `workspace:rw`           | Currently always `workspace:rw`. Reserved for future read-only / agent-only scopes. |

## Validation rules (workspace side)

The workspace verifies, in order:

1. Signature valid against `WORKER_JWT_SECRET`.
2. `iss == "carbide-control"`.
3. `aud == "workspace:#{ENV['WORKSPACE_PROJECT_ID']}"`.
4. `exp > now`.
5. `project_id == ENV['WORKSPACE_PROJECT_ID'].to_i`.
6. `user_id` is a positive integer.
7. `scope` is in the allowlist `[workspace:rw]`.

Failing any check returns 401 from the WS upgrade and the connection is closed
before any worker command is processed.

## Future claims (reserved)

- `agent_id` — when an agent (not a human) is connecting on the user's behalf.
- `terminal_ids` — allowlist of terminal IDs the agent may attach to.
- `expires_after_idle` — kill the WS if no traffic for N seconds.

Do not add new required claims without bumping a version field, which would
also need to be a required claim. For now we accept that any breaking change
requires lockstep deployment of both repos.
