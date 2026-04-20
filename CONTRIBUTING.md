# Contributing to SRE Demo Platform

This repo is the canonical source of truth for the Holy Grail SRE demo platform. Every change goes through a PR — no direct pushes to `main`.

---

## Branch Strategy

```
main          ← protected. Always deployable. CI must pass.
  └── feat/<ticket>-<short-description>   new features
  └── fix/<ticket>-<short-description>    bug fixes
  └── obs/<ticket>-<short-description>    observability changes
  └── chaos/<ticket>-<short-description>  chaos engineering
  └── docs/<ticket>-<short-description>   documentation only
```

Examples:
- `feat/001-alertmanager-slack`
- `fix/002-alloy-river-semicolon`
- `obs/003-slo-error-budget-dashboard`
- `chaos/004-litmuschaos-pod-delete`

---

## Commit Convention (Conventional Commits)

```
<type>(<scope>): <short summary>

[optional body — what and why, not how]

[optional footer: Closes #issue]
```

**Types:**

| Type | When to use |
|------|-------------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `obs` | Observability change (dashboards, alerts, scrape configs) |
| `hpa` | HPA tuning |
| `chaos` | Chaos engineering additions |
| `docs` | Documentation only |
| `ci` | CI pipeline changes |
| `refactor` | Refactor without behaviour change |
| `chore` | Dependency bumps, cleanup |

**Scopes:** `alloy`, `prometheus`, `loki`, `tempo`, `grafana`, `boutique`, `hpa`, `scripts`, `ci`, `docs`

**Examples:**
```
feat(alloy): add spanmetrics exemplar forwarding
fix(hpa): reduce cartservice maxReplicas 8→5 to prevent scheduling storm
obs(grafana): add SLO error budget burn rate panel
docs(readme): add chaos engineering roadmap section
```

---

## Pull Request Checklist

Before opening a PR, verify:

- [ ] `kubectl apply --dry-run=client -f <changed-file>` passes locally
- [ ] `bash scripts/verify-stability.sh --short` passes on your local cluster
- [ ] No secrets or kubeconfig files are staged (`git diff --cached`)
- [ ] Commit messages follow Conventional Commits
- [ ] `README.md` updated if you added a new script, endpoint, or design decision
- [ ] The `## Design Decisions` section in README updated if you changed HPA tuning, resource limits, or priority classes

---

## Local Validation

Run these before pushing:

```bash
# Validate all k8s manifests
for f in $(find k8s -name '*.yaml' | grep -v charts); do
  kubectl apply --dry-run=client -f "$f" && echo "✓ $f" || echo "✗ $f"
done

# Full health check
bash k8s/scripts/verify-stability.sh --short

# Check node budget
bash k8s/scripts/manage.sh budget
```

---

## Adding a New Tool / Service

1. Create a new directory under `k8s/observability/<tool>/` or `k8s/boutique/`
2. Single YAML manifest per component (ConfigMap + Deployment/DaemonSet + Service)
3. Set `priorityClassName` — observability tools get `observability-high`, node agents get `system-node-critical`
4. Set resource `requests` and `limits` — document the math in a comment block at the top of the YAML
5. Add a `terminationGracePeriodSeconds` if the component has a WAL, buffer, or in-flight data
6. Add the new endpoint to the `## Endpoints` table in README
7. Add any new `manage.sh` commands to the Operations section

---

## Image Pinning Policy

All images **must** be pinned to an explicit version tag. No `latest`. No `main`.

```yaml
# ✅ correct
image: grafana/tempo:2.4.1

# ❌ wrong
image: grafana/tempo:latest
image: grafana/tempo
```

When upgrading an image, document the reason and any config changes in the commit body.

---

## Secrets Policy

**Never commit secrets.** This includes:
- Grafana passwords
- API keys
- kubeconfig files
- Any base64-encoded credentials

The `.gitignore` covers common patterns but is not a substitute for awareness. Use `git diff --cached` before every commit.
