# Top-level rationale doc for the operator. Real Ruby code lands here later.
# This file exists so the directory is tracked in git.

# Operator design notes

## Why Ruby + kubeclient (not Go + kubebuilder)

Keeps the project monolingual with the control-plane Rails app. The operator
loop is small (one CR type, ~7 K8s object types to manage). Trading
kubebuilder's generators + leader election + caching machinery for the ability
to share models, JWT code, and connection pooling with the Rails side.

If the operator outgrows kubeclient (multi-CRD, leader election across
replicas, performance), the migration path is: extract object builders (already
pure functions of CR spec) into a separate package, rewrite the watch loop in
Go, keep the same CR contract. Object builders are the asset; the loop is
incidental.

## Reconcile model

Standard level-triggered reconcile. Watch `Workspace` CRs (across all
namespaces, filtered to `carbide-system`). On any event:

1. Read current state of all owned objects (Namespace, Deployment, Service,
   PVC, IngressRoute, Secrets, ServiceAccount, RoleBinding, CNPG Database).
2. Compute desired state from CR spec via `object_builders/`.
3. Diff and apply (create-if-missing, patch-if-different, leave-alone-if-equal).
4. Update CR `.status` (phase, observed generation, conditions).

No state held in the operator process itself. Crash + restart is safe — the
next reconcile rebuilds everything from the cluster.

## Owner references

Every K8s object the operator creates gets an ownerReference back to the
Workspace CR. Deleting the CR cascades to everything via standard K8s GC. The
Namespace itself can't have an ownerReference to a Namespaced resource, so the
operator deletes it explicitly on CR deletion (after finalizer cleanup).

## Finalizer

`carbide.dev/workspace-cleanup` — added on first reconcile, removed only after
the operator confirms the Namespace and CNPG Database have been deleted.
Prevents orphaned resources if the CR is deleted while the operator is down.

## Status reporting

Three things touch `.status`:

1. Phase transitions (Pending → Provisioning → Ready, or → Failed).
2. URL once Ready (assembled from ingress.host + pathPrefix).
3. Conditions (`Ready`, `Provisioned`, `Healthy`) with reason + message.

`observedGeneration` lets the dashboard tell "the operator has seen my latest
spec change" vs "still acting on old spec".

## What goes in object_builders/

Pure functions. Input: `Workspace` CR spec + cluster context (operator's own
namespace, owner ref). Output: a `Kubeclient::Resource` ready to apply. No
network calls, no cluster reads, no state. Trivially unit-testable without a
cluster.

Each builder file owns one object type. Cross-cutting concerns (labels,
annotations, ownerReferences) live in a `BuilderContext` value object passed
into every builder.

## RBAC

The operator's ServiceAccount needs cluster-scoped permissions because it
creates Namespaces and Roles. Specifically:

- ClusterRole: `create/get/list/watch/delete/patch` on `namespaces`,
  `clusterroles`, `clusterrolebindings` (the last two only if we ever need to
  let workspaces see across namespaces, currently no).
- ClusterRole: `create/get/list/watch/delete/patch` within `ws-*` namespaces
  on `deployments`, `services`, `pods`, `persistentvolumeclaims`,
  `serviceaccounts`, `roles`, `rolebindings`, `secrets`, `configmaps`.
- ClusterRole: `create/get/list/watch/delete/patch` on `ingressroutes.traefik.io`.
- ClusterRole: `create/get/list/watch/delete/patch` on `databases.postgresql.cnpg.io`.
- ClusterRole: `create/get/list/watch/update/patch` on `workspaces.carbide.dev`
  (including the `/status` subresource).

The Rails app's ServiceAccount needs only:

- `create/get/list/watch/delete` on `workspaces.carbide.dev` in `carbide-system`.

That's the entire point of this split — RCE in Rails grants the attacker the
ability to create/delete Workspace CRs, nothing more.
