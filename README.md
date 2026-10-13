# Postiz on Railway

Run [Postiz](https://github.com/gitroomhq/postiz-app), the open-source social media scheduler, on Railway. It stays on the current Postiz release, and every version bump is smoke-tested before it reaches you.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/TEMPLATE_CODE?utm_medium=integration&utm_source=template&utm_campaign=postiz)

## What you get

Four services:

| Service | Source | Purpose |
|---|---|---|
| **Postiz** | `postiz/` in this repo | Web app, API and the Temporal workers that publish your posts. Public. |
| **Temporal** | `temporal/` in this repo | Workflow engine that Postiz uses to schedule and publish posts. Private. |
| **Postgres** | Railway Postgres | Postiz data and Temporal history, in separate databases. |
| **Redis** | Railway Redis | Cache and rate limits. |

Postiz's own docker-compose also runs Elasticsearch, a second Postgres, the Temporal UI and admin tools. None of them are needed to run Postiz: Temporal keeps its search data in Postgres here. That saves roughly 1 GB of RAM.

The template also fixes several problems that break a plain Postiz deploy on Railway:

- **Login on `*.up.railway.app`.** Postiz sets its login cookie for `.railway.app`. Current browsers reject it because `up.railway.app` is a public suffix, and you end up back on the login page ([postiz-app#1143](https://github.com/gitroomhq/postiz-app/issues/1143)). Older browsers accept it and then send your session to every other app under `railway.app`. The template rewrites the cookie to your app's own host.
- **Port.** Postiz's backend also reads `PORT` and takes the public port when Railway sets it ([postiz-app#632](https://github.com/gitroomhq/postiz-app/issues/632)). Here nginx listens on `PORT` (8080) and the backend stays on 3000.
- **Start order.** Railway starts all services at once. If Postiz's workers start before Temporal is ready, they never connect and posts stay queued forever without an error ([postiz-app#1550](https://github.com/gitroomhq/postiz-app/issues/1550), [#2035](https://github.com/gitroomhq/postiz-app/issues/2035)). Postiz waits for Temporal before it starts.
- **Stalled workers.** A watchdog checks every minute that a worker is polling Temporal. If none has polled for about eight minutes, it restarts the workers.
- **Missed posts.** `RUN_CRON` is on, so Postiz checks every hour for posts that should have gone out in the last three hours and publishes them.
- **First sign-up.** Postiz lets whoever signs up first own the instance. The template creates your account on first boot, before the public URL opens, and keeps sign-ups closed.

## After deploying

1. Open the Postiz service's public URL.
2. Sign in with `POSTIZ_ADMIN_EMAIL` and `POSTIZ_ADMIN_PASSWORD`. You'll find both in the Postiz service's **Variables** tab. The password was generated for you.
3. Add channels. Each social network needs an app you create on its developer site, with the keys set as variables on the Postiz service. Use `https://<your-domain>/integrations/social/<provider>` as the redirect URL. See [Postiz's provider guides](https://docs.postiz.com/self-host/providers/overview) for the exact variable names, for example `X_API_KEY` and `X_API_SECRET`, or `LINKEDIN_CLIENT_ID` and `LINKEDIN_CLIENT_SECRET`.

## Variables

Postiz service:

| Variable | Default | Purpose |
|---|---|---|
| `POSTIZ_ADMIN_EMAIL` | you enter it | Account created on first boot |
| `POSTIZ_ADMIN_PASSWORD` | generated | Password for that account |
| `DISABLE_REGISTRATION` | `true` | Only one sign-up allowed, the account above. Set to `false` to let team members sign up |
| `JWT_SECRET` | generated | Signs login sessions |
| `MAIN_URL`, `FRONTEND_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | Your public URL |
| `NEXT_PUBLIC_BACKEND_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}/api` | API URL used by the browser |
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | Postgres |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` | Redis |
| `TEMPORAL_ADDRESS` | `${{Temporal.RAILWAY_PRIVATE_DOMAIN}}:7233` | Temporal |
| `RUN_CRON` | `true` | Hourly check for missed posts |
| `OPENAI_API_KEY` | empty | Optional. Turns on the AI features |

Any other [Postiz variable](https://docs.postiz.com/self-host/configuration/reference) can be added the same way: social network keys, email (`EMAIL_PROVIDER`, `RESEND_API_KEY` or SMTP), Cloudflare R2 storage, short links.

Temporal service: `POSTGRES_SEEDS`, `DB_PORT`, `POSTGRES_USER` and `POSTGRES_PWD` point at the Postgres service. Nothing to change.

Public networking for Postiz should point at port `8080`, the port Railway gives the service by default.

### Account notes

- The account is only created on the first boot. Changing `POSTIZ_ADMIN_PASSWORD` later does not change it. Use Postiz's settings instead.
- Configure email after the first boot. If an email provider is set when the account is created, Postiz requires you to activate it from an email first.
- To invite team members, set `DISABLE_REGISTRATION` to `false`, send the invites, and set it back once they have joined.

## Storage

Uploads (images and videos you attach to posts) are stored on a volume mounted at `/uploads` on the Postiz service and served from `https://<your-domain>/uploads/`. Social networks fetch media from that URL when they publish, so it has to stay public.

To use Cloudflare R2 instead, set `STORAGE_PROVIDER=cloudflare` and the `CLOUDFLARE_*` variables from [Postiz's docs](https://docs.postiz.com/self-host/configuration/reference). Postiz only supports R2, not other S3-compatible storage.

Postgres holds everything else, including Temporal's databases (`temporal` and `temporal_visibility`). Railway's Postgres backups cover all of it.

Because Postiz has a volume, each redeploy has a short downtime while the old container stops and the new one starts.

## Updates

This template pins the Postiz and Temporal versions. A GitHub Action checks for new releases every day:

- New Postiz releases are picked up as soon as their image is published.
- Temporal patch releases are bumped weekly, or together with a Postiz release.
- New Temporal minor versions (1.32 to 1.33) are bumped by hand, because Temporal must be upgraded one minor version at a time.
- Every bump is built and smoke-tested with the full stack before it is merged. Failed bumps open an issue instead.

When a bump lands, Railway shows an **update available** notice in your project. Updates are opt-in: apply them when it suits you. Your data is kept. Postiz migrates its database on start, and Temporal migrates its schema on start.

## Running it locally

`docker compose up` runs the same four services, with Postiz on `http://127.0.0.1:39100`. Postiz expects its public URL in the `Host` header, so open it through a host name that points to 127.0.0.1, or run the smoke test:

```bash
./scripts/smoke-test.sh
```

It builds both images, starts the stack and checks that the web UI loads, the seeded account can log in, strangers can't sign up, the workers poll Temporal and run Postiz's hourly job, and accounts, uploads and Temporal history survive a restart.

## License

The files in this repository are MIT licensed. Postiz itself is [AGPL-3.0](https://github.com/gitroomhq/postiz-app/blob/main/LICENSE) and runs from the unmodified official image. Temporal is [MIT](https://github.com/temporalio/temporal/blob/main/LICENSE).
