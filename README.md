# Rationale

I followed the instructions to my best ability. The 5 second restriction combined with
the firewall restriction presented an interesting challenge. I ended up using two local 
models with Ollama on my AMD Radeon RX 7900 XTX: Qwen 2.5 vl (7b), and Gemma 3 (4b). 

Qwen handles the images. It views them and attempts to transcribe and categorize them. 
It returns its results and they are checked against the user inputted data. If they don't 
perfectly match then it sends the full text to Gemma 3 to attempt to find miscatigorized 
data. Once everything is complete, the program returns the results to the user with notes 
on any decisions it made.

The program will sometimes take more than 5 seconds to process a request, but that is 
because of model cold start. When the models are warm I measured the Qwen step takes on average 
3.5 seconds, and the (optional) Gemma step takes about 1 second. Since this demo is running on 
my personal computer it has to load the models from disk on the first run.

I used Ruby on Rails and Claude Code (Opus 4.8 High) to build this project. I was most 
comfortable guiding the AI in Rails since I already have a fair bit of experience with it.

There are errors and false validations, but I tried to make the system fail to "Needs review" 
more often than not. It isn't perfect, but it demonstrates the idea is possible. With a 
little more compute (for larger image models) and about a week of dev time, this would be a 
great little app to solve the proposed issue.

The project is currently running on a cloud VPS with Cloudflare proxy in front of it for cache 
and traffic control. The cloud VPS is connected to my personal computer over Tailscale, where 
my RX 7900 XTX is running Ollama. I did have to put a login page so randoms on the internet 
wouldn't be running the AI on my home machine. I know the Cloudflare Turnstile may not actually 
be allowed per the client's instructions, but I needed that to protect my own hardware and 
electricity bill. On a real deployment one could hypothetically drop the login and Turnstile 
and have it all behind a firewall.

Now, for the rest of the readme with the setup instructions :)

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
cp env.example .env
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
