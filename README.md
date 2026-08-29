# carbide2-control

Control plane + Kubernetes operator for [carbide2-server][server]. Provisions
per-project workspace pods on demand from a web dashboard.

This repo is one of three:

| Repo                                                                | Role                                                                 |
| ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| [carbide2-server](https://github.com/fdimitri/carbide2-server)      | Per-workspace Rails app + EventMachine worker. One deployment per project. |
| [carbide2-client](https://github.com/fdimitri/carbide2-client)      | Vue 3 SPA. Talks to whichever workspace the user is currently in.    |
| **carbide2-control** (this repo)                                    | Single cluster-wide deployment. Owns users, project registry, dashboard, JWT minting, and the operator that spawns workspace pods. |

## What it is

Two processes, one codebase, one Helm chart, one Docker image, two entrypoints:

1. **`bin/rails server`** — the **control-plane web app**.
   - Serves the dashboard at `app.<cluster>.example.com` (or `/` on the cluster).
   - User auth (Devise). Owns the canonical `users` and `project_memberships` tables.
   - `POST /api/projects` creates a `Workspace` Custom Resource. Does not talk to Helm or kubectl.
   - Mints short-lived per-project JWTs that workspace pods verify on WebSocket connect.

2. **`bin/operator`** — the **Kubernetes operator**.
   - Watches `Workspace` Custom Resources via `kubeclient`.
   - Reconciles each one into the right shape of K8s objects (Namespace, Deployment, Service, PVC, IngressRoute, ServiceAccount, RoleBinding).
   - Reports status back on the CR (`.status.phase = Pending|Provisioning|Ready|Failed`).
   - The Rails app **never** shells out to `helm` or `kubectl`. The operator is the only thing with cluster-write RBAC.

## Why this split

[carbide2-server][server] is a per-project pod with per-project state (DB, PVC,
deployment). Creating a new project requires creating new cluster resources, but
the workspace pod itself has no business holding that authority. The control
plane owns the cross-project surface (users, project list, provisioning) and
delegates the actual K8s mutations to the operator, which is a small focused
process with tightly-scoped RBAC.

Long-term this lets us add: workspace pause/resume, auto-suspend on idle, per-user
quotas, scheduled backups — all as new fields on the `Workspace` CR, not as new
shell-outs.

## Repository layout (planned — currently scaffold only)

```
.
├── Gemfile                 Rails 8.1 + kubeclient
├── app/                    Control-plane Rails app
│   ├── controllers/
│   │   ├── application_controller.rb
│   │   └── api/
│   │       ├── projects_controller.rb      POST -> creates Workspace CR
│   │       ├── ws_tokens_controller.rb     POST -> mints per-project JWT
│   │       └── sessions_controller.rb      Devise
│   └── models/
│       ├── user.rb                         Devise user (moved from server)
│       ├── control_project.rb              {id, name, owner, namespace, ...}
│       └── project_membership.rb           {user, control_project, role}
├── bin/
│   ├── rails                               control-plane web app
│   └── operator                            reconcile loop entrypoint
├── operator/
│   ├── workspace_reconciler.rb             watches + reconciles Workspace CRs
│   ├── kube_client.rb                      kubeclient wrapper
│   └── object_builders/                    pure functions: CR spec -> K8s objects
│       ├── namespace.rb
│       ├── deployment.rb
│       ├── service.rb
│       ├── pvc.rb
│       ├── ingressroute.rb
│       └── rbac.rb
├── charts/
│   └── control-plane/                      Helm chart for this repo's two Deployments
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment-rails.yaml
│           ├── deployment-operator.yaml
│           ├── rbac.yaml                   cluster-scoped RBAC for the operator
│           ├── service.yaml
│           ├── ingressroute.yaml
│           ├── database.yaml               CNPG Database CR: carbide_control
│           └── jwt-secret.yaml             RSA signing key for control (not shared)
├── deploy/
│   └── crd-workspace.yaml                  THE Workspace CRD. The contract.
├── config/
│   └── ...                                 Rails config
└── db/
    └── ...                                 Rails migrations
```

## The `Workspace` Custom Resource

See `deploy/crd-workspace.yaml` for the schema. Summary:

```yaml
apiVersion: carbide.dev/v1
kind: Workspace
metadata:
  name: ws-42
  namespace: carbide-system        # operator watches this namespace
spec:
  projectId: 42                    # numeric id, matches control-plane DB
  ownerEmail: alice@example.com    # for display + audit
  workspaceImage: carbide2:dev     # what to run
  workspaceImageTag: dev
  storageSize: 1Gi
  postgres:
    clusterName: carbide-pg
    clusterNamespace: carbide-system
  git:                             # optional initial clone
    cloneUrl: https://github.com/foo/bar.git
    ref: main
  ingress:
    pathPrefix: /w/42
    publicPort: 8080
status:
  phase: Ready                     # Pending | Provisioning | Ready | Failed
  message: ""
  namespace: ws-42                 # actual namespace created
  url: http://localhost:8080/w/42/
  observedGeneration: 3
  conditions:
    - type: Ready
      status: "True"
      lastTransitionTime: "2026-06-02T00:00:00Z"
```

## JWT contract with workspace pods

The control plane mints, [carbide2-server][server] verifies. Both repos hold a
copy of `JWT_CLAIMS.md`; keep them in sync by hand.

```json
{
  "iss": "carbide-control",
  "sub": "user:42",
  "aud": "workspace:42",
  "exp": 1733184000,
  "iat": 1733183700,
  "user_id": 42,
  "user_email": "alice@example.com",
  "project_id": 42,
  "scope": "workspace:rw"
}
```

Signed with RS256 against an RSA key held only by the control plane (the
`workspace-jwt` Secret). Workspace pods verify with the public key fetched from
`/.well-known/jwks.json`; nothing is mirrored into their namespaces.

## Status

**Scaffold only.** No working code yet. Next steps:

1. CRD schema review (see `deploy/crd-workspace.yaml`).
2. Rails app scaffold (`rails new --api`).
3. Operator reconcile loop (Ruby + `kubeclient`).
4. Helm chart for this deployment.
5. Migrate `User` + `ProjectMembership` out of carbide2-server into here.
6. Update [carbide2-server][server] to accept control-minted JWTs.
7. Add "Clone from git" action in carbide2-server + carbide2-client (in-workspace, only for empty projects).

## License

GPL-3.0. Same as [carbide2-server][server] and [carbide2-client][client].

[server]: https://github.com/fdimitri/carbide2-server
[client]: https://github.com/fdimitri/carbide2-client
