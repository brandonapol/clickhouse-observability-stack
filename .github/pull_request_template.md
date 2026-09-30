Closes #N

## What

One paragraph. What changed and why.

## Changes

- Bullet list of specific changes

## PR Type

- [ ] Bug fix
- [ ] Feature / new component
- [ ] Version bump
- [ ] Refactor
- [ ] Docs
- [ ] Chore / tooling

## Surface

- [ ] App-of-apps or environment overrides (`cluster-configs/`)
- [ ] Cluster nodes (`cluster-nodes/`)
- [ ] Common library chart (`helm-templates/common/`)
- [ ] Scripts / local cluster
- [ ] CI / workflows
- [ ] Docs only

## Testing

- [ ] `make check` and `make test` pass, and `tests/golden` is regenerated
- [ ] Deployed to a fresh kind cluster (`make cluster/up`) and every Application reached Synced / Healthy
- [ ] Checked the result in Grafana (dashboards, Explore queries)
- [ ] Not deployed: docs, tooling, or a change `make check` fully covers

## Notes

<!-- Optional. Tradeoffs, follow-ups, things reviewers should know. -->
