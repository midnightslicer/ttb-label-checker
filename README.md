# TTB Label Verification

A Ruby on Rails application that checks alcohol label images against submitted
application data. Each label image is sent to a **local Ollama vision model**,
the printed fields are extracted, and every field is compared against the
applicant-supplied values to produce a per-field pass/fail verdict
(**Approve / Needs Review / Reject**).

The UI follows the federal color palette used at ttb.gov and is mobile friendly.
All upload pages are protected by username/password login plus a Cloudflare
Turnstile challenge.

- **No outbound internet required at runtime** — Ollama runs locally on the host.
- **Single Docker container**, configured entirely through `.env`.
- **SQLite** for all persistence (app data + Solid Queue job queue, WAL mode).
- **Batch jobs survive the browser tab closing** — they run in Solid Queue.

---

## Prerequisites

- Docker + Docker Compose
- [Ollama](https://ollama.com) running on the host, with a vision model pulled:
  ```bash
  ollama pull gemma3:12b
  ```

## Quick Start

```bash
cp .env.example .env
# Fill in SECRET_KEY_BASE (generate one):
bin/rails secret
# Set AUTH_USERNAME / AUTH_PASSWORD, and optionally the Turnstile keys.

docker compose up --build
```

The app is served at <http://localhost:3000>. Sign in with the credentials you
set in `.env`, then use **Single Label** or **Batch Upload**.

## Configuration (`.env`)

| Variable | Purpose |
|---|---|
| `OLLAMA_URL` | Ollama endpoint. Use `http://host.docker.internal:11434` in Docker. |
| `OLLAMA_MODEL` | Vision model name (default `gemma3:12b`). Any Ollama vision model works. |
| `OLLAMA_TIMEOUT` | Per-request timeout in seconds (default `120`). |
| `SECRET_KEY_BASE` | Rails secret. Generate with `bin/rails secret`. |
| `AUTH_USERNAME` / `AUTH_PASSWORD` | Login credentials for the upload pages. |
| `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` | Cloudflare Turnstile keys. Leave blank to disable the challenge. |
| `MAX_BATCH_SIZE` | Maximum rows per batch (default `300`). |
| `SOLID_QUEUE_IN_PUMA` | `1` runs the job worker inside Puma (single container). |

### Authentication & Turnstile

The upload pages require a session login. Credentials come from `AUTH_USERNAME` /
`AUTH_PASSWORD`. The login form is additionally guarded by a
[Cloudflare Turnstile](https://developers.cloudflare.com/turnstile/) challenge,
verified server-side. Get keys from the Cloudflare dashboard
(Turnstile → Add site). If `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` are left
blank, the challenge is skipped — convenient for local development.

## Batch CSV format

Upload a CSV manifest **and** all referenced image files together. The CSV header
must be:

```
filename,brand_name,class_type,abv,net_contents,producer,country_of_origin
```

Each `filename` must exactly match an uploaded image filename (including
extension). A template is downloadable from the Batch Upload page.

## How verdicts are decided

- Each field is normalized (case, whitespace, punctuation) and compared:
  exact → **match**, one contains the other → **fuzzy**, otherwise → **mismatch**.
- The Surgeon General **government warning** must match the required TTB language
  verbatim (the `GOVERNMENT WARNING:` prefix must be present and uppercase).
- **Reject** if any field mismatches or the warning isn't an exact match;
  **Needs Review** if only fuzzy matches remain; **Approve** if everything matches.

## Linux Ollama networking

`docker-compose.yml` adds `host.docker.internal:host-gateway` so that, on Linux,
`host.docker.internal` resolves to the host running Ollama. On macOS/Windows
Docker Desktop this is automatic. Alternatively set `OLLAMA_URL` to the host
gateway IP (often `172.17.0.1`) or run the container with `--network=host`.

## Swapping models

Change `OLLAMA_MODEL` in `.env` and restart. Any Ollama vision model works.

## Known limitations

- Heavily stylized fonts, very low resolution images, or unusual layouts reduce
  extraction accuracy.
- The first request after Ollama starts (or after a model is unloaded) is slow
  due to model cold-start; subsequent requests are faster.
- Verdicts are advisory and intended to assist human review, not replace it.

## Development

```bash
bin/rails db:prepare
bin/rails server          # http://localhost:3000
```

With Turnstile keys unset, sign in using the default `AUTH_USERNAME` /
`AUTH_PASSWORD` (`admin` / `password` if not overridden).
