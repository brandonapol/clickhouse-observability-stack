# `AGENTS.md`

## Purpose

These instructions tell coding agents how to work in this repository. [`CLAUDE.md`](CLAUDE.md) imports this
file, so this is the one place to edit — never write a second copy of a rule somewhere else.

This repository is a GitOps deployment, not an application. An Argo CD app-of-apps chart deploys an OpenTelemetry
pipeline that stores traces, logs and metrics in ClickHouse, with Cerberus translating Grafana's PromQL, LogQL
and TraceQL into ClickHouse SQL. There is no application code: every file is YAML, a shell script, or docs.
[`README.md`](README.md) is the user-facing guide and the record of design decisions; read its **Design
decisions** section before changing how components fit together.

### Repo map

```text
cluster-configs/app-of-apps/                  Helm chart: one Argo CD Application per entry in .Values.applications
cluster-configs/app-of-apps/app-of-apps-<env>.yaml   the one Application you kubectl apply per environment
cluster-configs/overrides/values-<env>.yaml   per-environment values the app-of-apps chart ingests
cluster-configs/argocd/values.yaml            Argo CD's own Helm values: footprint and the custom health checks
cluster-nodes/<app>/                          one chart per installed app, rendered entirely through common
helm-templates/common/                        the library chart every object is rendered through (see its README)
tests/charts/common-fixture/                  an application chart that exercises common, with its unit tests
tests/golden/<env>/                           every node rendered as Argo CD deploys it, per environment (generated)
scripts/render.bash                           produces tests/golden
scripts/check-structure.bash                  enforces the layout rules below
scripts/check-manifests.bash                  kubeconform and container policy over tests/golden
scripts/kind-up.sh, kind-down.sh              create and delete the local kind cluster
scripts/port-forward.sh                       forward Grafana, Argo CD, Cerberus and OTLP to localhost
kind-config.yaml                              the local cluster definition
git/hooks/                                    the pre-commit hook (`make setup/hooks`)
```

### How a value reaches a pod

```text
helm-templates/common/templates/_defaults.tpl     library defaults
  < cluster-nodes/<app>/values.yaml               the app, environment-neutral
  < cluster-configs/app-of-apps/values.yaml        global: {} and the application list (waves, namespaces)
  < cluster-configs/overrides/values-<env>.yaml    global: and applications.<app>.values for this environment
```

The app-of-apps chart renders each child Application with `helm.valuesObject` set to `global` merged with
`applications.<app>.values`, so an environment changes an app by writing the keys it wants under
`applications.<app>.values` and nothing else. Maps deep-merge; `null` deletes; lists replace whole.

## Working in this repository

### Use Makefile targets (always)

Use the existing targets rather than crafting your own shell commands. If an action needs to be repeatable,
add a target. `make help` lists everything.

| Target                      | What it does                                                                 |
| --------------------------- | ---------------------------------------------------------------------------- |
| `make setup`                | installs every check tool (Go, Python 3 and Node required) and the git hooks    |
| `make check`                | the whole gate CI runs: `check/lint`, `check/golden`, `check/manifests`        |
| `make check/lint`           | yamllint, shellcheck, `check/structure`, actionlint, cspell                   |
| `make check/structure`      | the cluster-configs and cluster-nodes layout rules below                      |
| `make check/golden`         | fails when `tests/golden` differs from a fresh render                         |
| `make check/manifests`      | kubeconform over `tests/golden`, plus memory limits and pinned images         |
| `make generate`             | re-renders `tests/golden`; run it after any chart or values change            |
| `make test`                 | every offline test; today `test/unit`                                        |
| `make test/unit`            | rebuilds `file://` dependencies, then runs every helm-unittest suite          |
| `make cluster/up`           | kind cluster, Argo CD, the local app-of-apps (~10 min first run, ~3 GB RAM)   |
| `make cluster/port-forward` | Grafana `:3000`, Argo CD `:8080`, Cerberus `:8081`, OTLP `:4317`/`:4318`       |
| `make cluster/down`         | deletes the kind cluster                                                      |

GNU make is required. On macOS use `gmake`, which is what `git/hooks/pre-commit` does.

New targets follow the existing families: `setup/...`, `check/...`, `generate`, `test/...`, `cluster/...`.

### What the checks enforce

`.github/workflows/check.yml` runs `make check` on every pull request and every push to `main`, and
`make setup/hooks` installs a pre-commit hook that runs `make check/lint`, so nothing here is advisory.

- **YAML** — `yamllint --strict` against `.yamllint.yaml`. Line length is off (dashboard JSON and long
  comments), but indentation, trailing spaces, brace spacing and truthy values are enforced.
- **Shell** — shellcheck on everything in `scripts/` and `git/hooks/`.
- **Layout** — `scripts/check-structure.bash`; see Cluster configs and Cluster nodes below.
- **Golden renders** — `tests/golden/<env>/` holds every node rendered exactly as Argo CD would for that
  environment: `scripts/render.bash` renders the app-of-apps chart with `values-<env>.yaml`, then renders
  each generated Application's chart with its `valuesObject`, release name and namespace, against Kubernetes
  `1.34.0`. `make check/golden` re-renders and diffs, so every PR shows its exact effect on each cluster —
  including the `checksum/config` change that means pods will roll. Never edit `tests/golden` by hand; run
  `make generate` and commit it. CRDs from `crds/` are not rendered into it.
- **Schemas** — kubeconform in strict mode over `tests/golden` and the bootstrap Applications. The Kubernetes
  schemas and the [datreeio CRDs catalog](https://github.com/datreeio/CRDs-catalog) are pinned to commit SHAs
  in `scripts/check-manifests.bash`, so the result never changes under you. A resource with no schema is an
  error, not a skip.
- **Container policy** — every container in a Deployment or ClickHouseInstallation has a memory limit and an
  image with a pinned tag other than `latest`.
- **Workflows** — actionlint on `.github/workflows/`.
- **Spelling** — `make check/spelling` runs cspell over every tracked file against `cspell.json`. American and
  British spellings are both accepted. A new proper noun (a chart, a vendor, a tool, a metric name) fails the
  build until it is added to `words` in `cspell.json`, kept sorted; this is the most common way a docs-only
  change goes red.

Nothing in `make check` or `make test` touches a cluster or a chart registry: every chart is local, and the
only network calls are git clones in `make setup` and kubeconform's pinned schema downloads. The same commit
gives the same result on a laptop and in CI.

`make check` proves the manifests are well-formed. It does not prove the stack works: ordering, health,
ClickHouse schema compatibility and Grafana queries are only exercised by deploying to kind.

### Cluster nodes

`cluster-nodes/<app>/` is one Helm chart per app: `clickhouse-operator`, `clickhouse`, `cerberus`,
`otel-collector`, `grafana` and `demo-load`. Each has the same shape:

```text
Chart.yaml               depends on file://../../helm-templates/common; appVersion is the app's version
Chart.lock               committed; charts/*.tgz is gitignored and rebuilt by make deps
values.yaml              the whole workload, in the schema helm-templates/common/README.md documents
templates/common.yaml    {{ include "common.all" . }} and nothing else
tests/*_test.yaml        helm-unittest suites
```

- **Never add a template to a node.** If a node needs something `common` can't express, add it to `common`
  with a fixture test, or use `objects` for a one-off manifest such as a custom resource.
- **A node's `values.yaml` is environment-neutral.** It holds what every environment shares, sized for the
  laptop profile that is actually tested. Credentials are never in a node: a Secret there is `create: false`,
  and an environment turns it on or pre-creates it.
- **Content with literal `{{` goes in a file, not in values**: Grafana dashboards live in
  `cluster-nodes/grafana/dashboards/*.json`, and the operator's ClickHouse config in
  `cluster-nodes/clickhouse-operator/files/`. Both are loaded with a `files` glob.
- **Vendored upstream files are copied verbatim at the pinned version**: the operator's CRDs in
  `cluster-nodes/clickhouse-operator/crds/` and its config files. yamllint and cspell skip them. Bumping the
  operator means replacing them from the new release.
- **Node tests pin the contracts between apps**: the Secret name the others read (`clickhouse-credentials`),
  the Service names and ports they dial (`clickhouse:9000`, `cerberus:8080`, `otel-collector:4317`), and the
  schema ownership rule (`create_schema: false`, `CERBERUS_AUTO_CREATE_SCHEMA: "true"`). Keep them when you
  change a node.

### Tests

- **A change to `helm-templates/common` needs a helm-unittest case** in
  `tests/charts/common-fixture/tests/`. Turn the feature on in the fixture's `values.yaml` and assert on the
  rendered object.
- **Always run tests through `make test/unit`.** helm-unittest renders the packaged
  `charts/common-<version>.tgz`, not the source directory, so a test run without `make deps` first can pass
  against stale templates. The tarballs are gitignored; `Chart.lock` is committed.
- **Check that a new test can fail.** Break the template it covers, watch it go red, and put the template back.

### Cluster configs

- **Environments are files, not branches.** `cluster-configs/overrides/values-<env>.yaml` and
  `cluster-configs/app-of-apps/app-of-apps-<env>.yaml` come in pairs; the bootstrap Application loads
  `../overrides/values-<env>.yaml`, and its `repoURL` and `targetRevision` match that file's.
- **The application list lives in `cluster-configs/app-of-apps/values.yaml`**, one entry per
  `cluster-nodes/<app>` with an integer `syncWave` and, when not `observability`, a `namespace`. An
  environment never adds an app; it disables one with `enabled: false` or changes one under `values:`.
- **Child Applications are generated.** Their finalizer, automated prune and self-heal, `CreateNamespace` and
  `ServerSideApply` come from `templates/application.yaml`; change them there, with a test in
  `cluster-configs/app-of-apps/tests/`.
- `local` is the kind cluster and the only environment that is actually deployed and tested. `prod` is a
  worked example of production overrides: no demo load, no laptop tuning, larger resources, and every Secret
  pre-created.

Argo CD deploys from `main` on GitHub, never from your working tree, so a change is not live on a cluster until
it is merged (or until you point `targetRevision` at your branch in a throwaway cluster — never commit that).

### Sync waves and health

The waves are: operator `0`, ClickHouse `1`, Cerberus `2`, collector and Grafana `3`, demo load `4`. A new
component takes the wave after everything it needs. Waves only mean something because
`cluster-configs/argocd/values.yaml` adds two Lua health checks — a child `Application` is healthy only once it
is Synced and Healthy, and a `ClickHouseInstallation` only once the operator reports `Completed`. If you add a
custom resource that later waves depend on, add a health check for it there too.

### Adding or changing a component

1. **Node** — `cluster-nodes/<app>/`: copy the closest existing one (`cerberus` for a plain service,
   `clickhouse` for a custom resource), rename it in `Chart.yaml`, write `values.yaml`, run `make deps`, and
   add a `tests/<app>_test.yaml` that pins whatever other apps depend on.
2. **Application** — add `<app>: {syncWave: N}` to `cluster-configs/app-of-apps/values.yaml`.
3. **Environments** — add whatever differs per environment to each `values-<env>.yaml`; credentials only
   in `values-local.yaml`.
4. **Resources** — every container sets a CPU and memory request and a memory limit (`make check` enforces
   the limit). The local stack has to fit a laptop (about 2.4 GB measured); say what the new component costs.
5. **README** — update the Components table, the sync-wave table, the sizing table, and the layout or
   troubleshooting sections if they change.
6. `make generate`, `make check`, `make test`, then deploy to kind (below).

A version bump is the same shape: change the image tag and `appVersion` in the node, the README Components
table, and `tests/golden` in the same commit. Bump one component per PR unless two must move together.

### Coupled versions

- **Cerberus owns the ClickHouse tables.** It runs with `autoCreate.schema: true` and is validated against
  the ClickHouse exporter's v0.152 table layout; the collector's `clickhouse` exporter runs with
  `create_schema: false`. Bumping either the collector image or Cerberus can break inserts or queries without
  any manifest changing, so a bump to either one needs a kind deploy and a query in Grafana, not just
  `make check`.
- **The Altinity operator** changes its CRD surface between minor versions (0.27.4 removed
  `user/k8s_secret_password`). Read its release notes before bumping.
- **The operator's CRDs and config files are vendored** into `cluster-nodes/clickhouse-operator/crds/` and
  `files/`. Bumping the operator image means replacing them from the same release.
- **telemetrygen** in `cluster-nodes/demo-load` tracks the collector-contrib version.

### Secrets

The ClickHouse password and Grafana's `admin`/`admin` in `cluster-configs/overrides/values-local.yaml` are
deliberately public, local-only values. Nodes never create a Secret by default, and `prod` expects every
Secret to be pre-created. Never commit any other credential, token or
key, and never replace these with real ones — a real deployment uses a secret manager (the README names
External Secrets and Sealed Secrets).

### Verification before claiming done

- Run `make check` before every push.
- For anything that changes what runs — values, templates, versions, waves, health checks — deploy it:
  `make cluster/up`, wait for `kubectl -n argocd get applications` to show every app Synced / Healthy, then
  `make cluster/port-forward` and check the result in Grafana. The README's **What you should see** section
  lists the expected demo-load numbers.
- Report exactly what was run. Never write "tested on kind" or "verified in Grafana" in a PR or commit unless
  that happened in this session. `make check` alone is `make check`, and say so.
- If a symptom persists after a fix, check the environment before re-diagnosing: which revision Argo CD
  synced, whether the Application was refreshed, whether an old kind cluster is still running.

### Scope discipline

- **Advice is not a request for edits.** When asked to review, explain or advise, answer in chat and touch no
  files.
- **Build what was asked.** No new components, config knobs or abstractions nobody requested.
- **Ask before a large change** — a new component, a new chart source, or edits across more than ~10 files
  get two or three options with tradeoffs first.
- **Never fork or vendor an upstream chart without approval.** Prefer values, a pinned version, or an
  upstream issue.
- **Keep it laptop-sized.** Production hardening (HA ClickHouse, collector load balancing, real secrets) is
  listed in the README's **Before using this beyond a laptop**; don't fold it into unrelated changes.

### Say it once

YAML invites copy-paste. Write a Kubernetes object's shape once, in `helm-templates/common`; a node says only
what is particular to its app; an environment says only what differs for that environment. If two nodes
need the same new field, it goes in `common`, not in both.

### Pull request and commit conventions

- **PR titles use conventional commits:** `type: description`, lowercase and imperative —
  `feat: add tempo-compatible trace retention`, `fix: raise cerberus memory limit`,
  `chore: bump otel collector to 0.162.0`, `docs:`, `refactor:`.
- Branch names reflect the change: `feat/<short-description>`, `chore/bump-<component>-<version>`.
- Fill in [the PR template](.github/pull_request_template.md), including which surfaces the change touches and
  whether it was deployed to kind.
- One focused commit per PR.
