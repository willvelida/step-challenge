# Contributing to StepUp

Thanks for your interest! StepUp is a sample app demonstrating Dapr, Radius, and Drasi, so
contributions that make it clearer, more correct, or easier to run are especially welcome —
bug fixes, documentation, or deployment improvements.

## Getting started

1. Fork the repository and clone your fork.
2. Get it running locally with `./scripts/cluster-up.sh` (see [Run it locally](README.md#run-it-locally)), or `./scripts/db-up.sh` for just the database.
3. Make your change on a branch off `main`.

## Workflow

- **Requesting a feature?** Open a [feature request](https://github.com/willvelida/step-challenge/issues/new?template=feature_request.yml) issue *before* raising a pull request, so we can agree on the approach first. Bug fixes, docs, and small tweaks can go straight to a PR.
- Branch from `main` with a short, descriptive name (e.g. `feat/new-contest`, `docs/readme`, `fix/clock-boundary`).
- Keep pull requests focused — one logical change per PR.
- **CI must be green** before merge: the CI workflow builds the four service images and lints the Bicep templates.
- Deploys happen through the **Deploy** workflow on merge to `main` — don't hotfix the cluster by hand; roll forward with a follow-up PR.

## Commit messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org). Prefix the subject
with a type:

- `feat:` a new capability  ·  `fix:` a bug fix  ·  `refactor:` no behaviour change
- `docs:` documentation  ·  `build:` Dockerfiles/build  ·  `ops:` workflows and scripts  ·  `chore:` everything else

## Where things live

| Path | What |
|------|------|
| `src/` | the four services — `Simulator`, `Clock`, `Notifier` (.NET) and `Dashboard` (Vue) |
| `infra/` | Azure Bicep (`main.bicep`), the Radius app (`app.bicep`), and the OIDC templates |
| `drasi/` | the Drasi source, continuous queries, and reactions |
| `components/`, `k8s/` | Dapr components and shared Kubernetes manifests (Redis) |
| `data/` | database schema and seed SQL |
| `scripts/` | local (`cluster-*`, `db-*`) and Azure (`aks-*`, `setup-oidc`) lifecycle scripts |
| `docs/` | architecture notes and per-feature implementation plans |
| `.github/workflows/` | the CI and Deploy pipelines |

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
