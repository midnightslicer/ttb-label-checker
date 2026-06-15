# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Rails 8 app that verifies alcohol-beverage label photos against applicant-supplied
data for a TTB-style compliance workflow. A local **Ollama vision model** transcribes
the label; extracted fields are compared to the application; a smaller local **text
model** resolves the hard cases. Output is a per-field verdict: **Approve / Needs
Review / Reject**. Everything runs against local Ollama — **no outbound internet at
runtime** (a hard requirement: the target network blocks cloud ML endpoints).

## Commands

```bash
bin/ci                       # full CI: rubocop, bundler-audit, importmap audit, brakeman, tests
bin/rails test               # run the test suite
bin/rails test test/services/field_comparator_test.rb          # one file
bin/rails test test/services/field_comparator_test.rb:80       # one test by line
bin/rubocop                  # lint (rubocop-rails-omakase)
bin/rails db:prepare         # set up the dev DB
bin/rails server             # serve at http://localhost:3000
```

CI is defined in `config/ci.rb` (run via `bin/ci`). The GitHub workflow runs the same
steps **without** an Ollama instance available.

### Tests must be hermetic — the critical gotcha

CI has no Ollama. `FieldComparator#apply_llm_matches` **rescues `SemanticMatcher::MatchError`
and silently keeps the deterministic result**, so a test that unintentionally depends on
the LLM *passes locally* (Ollama is reachable) but *fails in CI* (the rescue changes the
outcome). Before relying on a verdict in a test, make sure the assertion is reached
deterministically — either every field resolves via string/`full_text` containment, or
`full_text` is blank (which short-circuits escalation in `apply_semantic_matches`).

Replicate the CI environment locally by pointing Ollama at a dead port:

```bash
OLLAMA_URL=http://127.0.0.1:9 bin/rails test
```

## Architecture: the verification pipeline

A label flows through these stages. Read them together — the logic spans the job and
three services.

1. **Entry** — `ReviewsController#create` (single) or `BatchesController#create` (CSV +
   images). Each creates a `LabelReview` (status `pending`) and enqueues a
   `LabelAnalysisJob`. Batches create one review per CSV row under a `BatchUpload`.

2. **`LabelAnalysisJob`** (`app/jobs/`, Solid Queue) orchestrates everything async:
   `ImagePreprocessor` → `OllamaService` → `FieldComparator`, then writes
   `extracted_fields`, `results`, `verdict`, and `status` back onto the review. Each
   job increments its batch's counters and calls `BatchUpload#update_status!` so batch
   status (`processing`/`complete`/`partial`/`failed`) is recomputed in real time.

3. **`ImagePreprocessor`** shells out to ImageMagick. The important part is the
   **best-effort label crop** (connected-components on a downscaled copy), not the
   sharpening — cropping is what keeps fine print (government warning, importer line)
   legible after downscale. Falls back to the whole frame if no label is detected.

4. **`OllamaService`** posts the image to the `VISION_MODEL` and returns extracted
   structured fields **plus `full_text`** (a verbatim transcription of all label text).
   `full_text` is the backbone of the matching fallbacks. Temperature 0.

5. **`FieldComparator`** decides the verdict in three tiers:
   - **Deterministic** per-field: normalize (lowercase, strip punctuation, collapse
     whitespace) then containment — exact → `true`, one contains the other → `"fuzzy"`,
     else `false`. `abv` is compared by leading numeric value; `country_of_origin` is
     optional.
   - **`full_text` containment**: an unresolved field whose value appears verbatim
     anywhere in `full_text` is promoted to a match (handles the vision model capturing
     the wrong party, e.g. importer vs bottler).
   - **`SemanticMatcher` (LLM)**: only the still-unresolved semantic fields
     (`brand_name`, `class_type`, `producer`, `country_of_origin`) escalate to the
     `MATCH_MODEL`, judged against `full_text`. Numeric fields never escalate.
   - Verdict: **reject** if any field mismatches or the warning isn't exact;
     **needs_review** if only fuzzy remain; **approve** otherwise.

### Government warning is special

The Surgeon General warning is checked **entirely in code** (never sent to the LLM)
against the verbatim required text in `FieldComparator::GOVERNMENT_WARNING`. The
comparison is **case-insensitive by design** — including the `GOVERNMENT WARNING:`
heading. This is deliberate: the small demo models don't reliably preserve casing (they
often drop or recase the heading), so a case-sensitive check would cause false rejects.
The all-caps-heading rule is enforced via the extraction prompt in `OllamaService`, not
the comparator. Don't add a case-sensitive prefix check unless the models are upgraded
to guarantee verbatim casing.

## Key conventions

- **Application field naming.** Columns are stored `app_*`; `LabelReview#application_data`
  strips the prefix to the bare keys (`brand_name`, …) that `FieldComparator` expects.
- **Active Storage blobs may be remote** — `LabelAnalysisJob#analyze` downloads to a
  tempfile (`blob.open`) rather than assuming a local path. `ImagePreprocessor` returns
  a tempfile the caller must `close!`.
- **Single-container by default.** `SOLID_QUEUE_IN_PUMA=1` runs the job worker inside
  Puma; SQLite in WAL mode (`config/initializers/sqlite.rb`) lets web + worker share it.

## Configuration & models

Config is entirely via `.env` (see `env.example`). Notable: `VISION_MODEL` (code
default `gemma3:12b`, but `qwen2.5vl:7b` is recommended/used in the demo), `MATCH_MODEL`
(`gemma3:4b`), `OLLAMA_URL` (use `http://host.docker.internal:11434` in Docker).
Swapping a model requires `ollama pull`-ing it first. With Turnstile keys blank the
login challenge is skipped (local dev).

## Deployment

Docker single container, deployed with **Kamal** (`config/deploy.yml`). Ollama runs on
separate hardware reached over Tailscale, not in the container. **Kamal tags images by
git SHA** — commit any Dockerfile/dependency changes before `kamal deploy` or the old
image gets redeployed.
