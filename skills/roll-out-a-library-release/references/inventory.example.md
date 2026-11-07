# Inventory (example)

Copy this file to `inventory.md` beside it and replace every value. All names below are invented.

## Library

| Field | Value |
|---|---|
| Package | `acme-core` |
| Manifest / lockfile | `package.json` / `package-lock.json` (`pnpm-lock.yaml` where noted) |
| Issue format | a number, or a tracker URL whose path holds `/story/<id>/` |
| Issue link in a pull request | `[ref-<id>]` in the body |
| Pull request conventions | assignee `<your-login>`; no reviewers for bump-only pull requests |

## Consumers

| Repository | Aliases | Path | Default branch | Host |
|---|---|---|---|---|
| acme-api | `api` | `./acme-api` | main | Heroku |
| acme-admin | `admin` | `./acme-admin` | master | Heroku |
| acme-workers | `workers` | `./daemons/acme-workers` | master | Heroku, no staging stage |
| acme-jobs | `jobs` | `./daemons/acme-jobs` | master | Clever Cloud |
| fn-thumbnailer | `thumbs` | `./functions/fn-thumbnailer` | main | container function |
| fn-indexer | `indexer` | `./functions/fn-indexer` | main | container function, production only |
| (every Heroku and Clever Cloud row) | `all` | | | |
| (every function row) | `functions` | | | |

Repository notes go here: a pnpm repository, a custom release-please branch name, the unit test command that
actually finds the tests, a legacy deploy script that must not be used.

## Heroku apps

| Repository | App | Stage | Method | Health URL | Healthy codes | Preboot |
|---|---|---|---|---|---|---|
| acme-api | `acme-api-dev` | dev | branch deploy (shape 2) | `https://acme-api-dev.example.com/` | 404 | no |
| acme-api | `acme-api-staging` | staging | branch deploy (shape 2) | `https://acme-api-staging.example.com/` | 404 | no |
| acme-api | `acme-api` | prod | `pipelines:promote -a acme-api-staging` | `https://api.example.com/` | 404 | yes |
| acme-admin | `acme-admin-staging` | staging | autodeploy (shape 1) | `https://acme-admin-staging.example.com/` | 401 | no |
| acme-admin | `acme-admin` | prod | `pipelines:promote -a acme-admin-staging` | `https://admin.example.com/` | 401 | yes |
| acme-workers | `acme-workers-dev` | dev | branch deploy (shape 2) | none, worker | | |
| acme-workers | `acme-workers`, `acme-workers-big` | prod | `pipelines:promote -a acme-workers-dev --to acme-workers,acme-workers-big` | none, worker | | |

Mark here a pre-production app that carries production credentials and must never be scaled up, and an app whose
web formation sits at 0 between deploys.

## Clever Cloud apps

| Repository | Stage | App id | Deploy command |
|---|---|---|---|
| acme-jobs | testing | `app_00000000-0000-0000-0000-000000000001` | `cd scripts && bash deploy-testing.sh` |
| acme-jobs | prod | `app_00000000-0000-0000-0000-000000000002` | `cd scripts && bash deploy-production.sh` |

## Container functions

| Repository | Image repository | IaC unit (dev) | IaC unit (prod) |
|---|---|---|---|
| fn-thumbnailer | `fn-thumbnailer` | `infra/dev/<region>/lambda/thumbnailer/` | `infra/prod/<region>/lambda/thumbnailer/` |
| fn-indexer | `fn-indexer` | none | `infra/prod/<region>/lambda/indexer/` |

Infrastructure repository: `./infra`. Image version key: `image_version` in `<unit>/function-config.hcl`.
Cloud profile used for the image registry and IaC: `<profile>`.
