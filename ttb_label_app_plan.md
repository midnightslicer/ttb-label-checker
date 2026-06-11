# TTB Label Verification App — Implementation Plan

## Overview

Ruby on Rails application that accepts alcohol label images (single or batch), sends
the image directly to a local Ollama vision model for field extraction, then compares
extracted fields against the submitted application data and returns a per-field
pass/fail verdict.

**Key constraints:**
- No outbound internet required at runtime — Ollama runs locally on the host
- Single Docker container, configured entirely via `.env`
- SQLite for all persistence (app data + job queue)
- Batch jobs must survive the user closing the browser tab

---

## Tech Stack

| Layer | Choice |
|---|---|
| Framework | Ruby on Rails 8 |
| Database | SQLite (WAL mode) |
| Background Jobs | Solid Queue (Rails 8 default, in-process via SOLID_QUEUE_IN_PUMA) |
| Vision + Extraction | Ollama HTTP API — `gemma3:12b` (Faraday) |
| File Storage | Active Storage (local disk) |
| Container | Docker (single container) |

---

## Gems to Add

```ruby
# Gemfile additions
gem "faraday"
gem "faraday-retry"     # retry on Ollama timeouts
```

Solid Queue and Active Storage ship with Rails 8.

---

## Environment Variables (`.env`)

```
# Ollama
OLLAMA_URL=http://host.docker.internal:11434
OLLAMA_MODEL=gemma3:12b

# Rails
RAILS_ENV=production
SECRET_KEY_BASE=<generate with rails secret>
RAILS_LOG_TO_STDOUT=true

# Optional
MAX_BATCH_SIZE=300
```

> **Docker networking note:** On Mac/Windows, `host.docker.internal` resolves to the
> host machine where Ollama is running. On Linux, set `OLLAMA_URL` to the host's
> gateway IP (typically `172.17.0.1`) or use `--network=host` in docker run.

---

## Data Models

### `LabelReview`

Represents one label check — whether submitted individually or as part of a batch.

```
id
batch_upload_id        integer, nullable (null = standalone review)
status                 string, default: "pending"
                       values: pending | processing | complete | failed

# Application data (what the applicant claimed)
app_brand_name         string
app_class_type         string
app_abv                string
app_net_contents       string
app_producer           string
app_country_of_origin  string, nullable

# Extracted data (what gemma3:12b found on the label)
extracted_fields       text (JSON blob)

# Results
results                text (JSON blob)
  # structure:
  # {
  #   "fields": [
  #     { "field": "brand_name", "app_value": "...", "label_value": "...",
  #       "match": true|false|"fuzzy", "note": "..." },
  #     ...
  #   ],
  #   "government_warning": { "present": true, "exact_match": true, "note": "..." },
  #   "verdict": "approve"|"reject"|"needs_review"
  # }

verdict                string, nullable  (approve | reject | needs_review)
error_message          text, nullable    (populated on failure)
ocr_raw_text           text, nullable    (store for debugging)

created_at
updated_at
```

Active Storage attachment: `label_image` (one attached image per review)

### `BatchUpload`

Groups multiple `LabelReview` records from a single bulk submission.

```
id
status                 string, default: "pending"
                       values: pending | processing | complete | failed | partial
total_count            integer, default: 0
completed_count        integer, default: 0
failed_count           integer, default: 0
created_at
updated_at
```

---

## File Structure

```
app/
  controllers/
    reviews_controller.rb
    batches_controller.rb
  jobs/
    label_analysis_job.rb
  models/
    label_review.rb
    batch_upload.rb
  services/
    ollama_service.rb
    field_comparator.rb
  views/
    layouts/
      application.html.erb
    reviews/
      new.html.erb          # single upload form
      show.html.erb         # results for one review
    batches/
      new.html.erb          # batch upload form
      index.html.erb        # job list (polling)
      show.html.erb         # batch detail with per-label results
    shared/
      _verdict_badge.html.erb
      _field_results_table.html.erb
config/
  database.yml
  storage.yml
Dockerfile
docker-compose.yml
.env.example
```

---

## Service Layer

### `OllamaService`

`app/services/ollama_service.rb`

Takes an image path, base64 encodes it, sends a single prompt to Ollama with the
image attached, and returns parsed structured fields as a Hash. Whitespace is
normalized on every returned field value before the hash is returned.

**System prompt (stable, sets model behavior):**
```
You are a JSON extraction API. You receive alcohol label images and return
structured JSON only. Your response must begin with { and end with }.
Do not use markdown. Do not use code fences.
```

**User prompt (lean, just the task):**
```
Extract these fields from the label. Return null for missing fields.
Normalize all whitespace to single spaces.

{"brand_name": null, "class_type": null, "abv": null, "net_contents": null,
"producer": null, "country_of_origin": null, "government_warning": null}
```

```ruby
class OllamaService
  class ExtractionError < StandardError; end

  SYSTEM_PROMPT = <<~PROMPT.strip
    You are a JSON extraction API. You receive alcohol label images and return
    structured JSON only. Your response must begin with { and end with }.
    Do not use markdown. Do not use code fences.
  PROMPT

  USER_PROMPT = <<~PROMPT.strip
    Extract these fields from the label. Return null for missing fields.
    Normalize all whitespace to single spaces.

    {"brand_name": null, "class_type": null, "abv": null, "net_contents": null,
    "producer": null, "country_of_origin": null, "government_warning": null}
  PROMPT

  def self.call(image_path)
    image_data = Base64.strict_encode64(File.binread(image_path))

    conn = Faraday.new(url: ENV.fetch("OLLAMA_URL")) do |f|
      f.request :json
      f.response :json
      f.request :retry, max: 2, interval: 1
      f.options.timeout = 30
    end

    response = conn.post("/api/generate") do |req|
      req.body = {
        model:       ENV.fetch("OLLAMA_MODEL", "gemma3:12b"),
        system:      SYSTEM_PROMPT,
        prompt:      USER_PROMPT,
        stream:      false,
        num_predict: 400,
        temperature: 0,
        images:      [image_data]
      }
    end

    raw = response.body["response"].to_s.strip
    # Strip markdown fences defensively — model may ignore instructions
    raw = raw.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip

    parsed = JSON.parse(raw)
    normalize_whitespace(parsed)
  rescue JSON::ParserError, Faraday::Error => e
    raise ExtractionError, "Ollama extraction failed: #{e.message}"
  end

  private

  def self.normalize_whitespace(extracted)
    extracted.transform_values do |v|
      v.is_a?(String) ? v.gsub(/\s+/, " ").strip : v
    end
  end
end
```

### `FieldComparator`

`app/services/field_comparator.rb`

Pure Ruby comparison logic. Takes application data hash and extracted fields hash,
returns the results JSON structure.

**Government Warning exact match string (must match verbatim, case-sensitive on
"GOVERNMENT WARNING:"):**

```
GOVERNMENT WARNING: (1) According to the Surgeon General, women should not drink
alcoholic beverages during pregnancy because of the risk of birth defects. (2)
Consumption of alcoholic beverages impairs your ability to drive a car or operate
machinery, and may cause health problems.
```

Store this as a constant. Compare by normalizing whitespace only (collapse multiple
spaces/newlines to single space, strip leading/trailing). Do NOT normalize case.
The "GOVERNMENT WARNING:" prefix must be uppercase and present.

**For other fields:**
- Normalize both sides: strip, downcase, collapse whitespace, remove punctuation
  except hyphens and slashes
- If normalized strings are equal → `match: true`
- If one contains the other (substring) → `match: "fuzzy"`, note the difference
- Otherwise → `match: false`

**Verdict logic:**
- Any field with `match: false` → `"reject"`
- Any field with `match: "fuzzy"` and no `false` → `"needs_review"`
- Government warning `exact_match: false` → always `"reject"` (hard requirement)
- All fields `match: true` and warning exact → `"approve"`

```ruby
class FieldComparator
  GOVERNMENT_WARNING = (
    "GOVERNMENT WARNING: (1) According to the Surgeon General, women should not " \
    "drink alcoholic beverages during pregnancy because of the risk of birth defects. " \
    "(2) Consumption of alcoholic beverages impairs your ability to drive a car or " \
    "operate machinery, and may cause health problems."
  ).freeze

  FIELD_MAP = {
    brand_name:        "brand_name",
    class_type:        "class_type",
    abv:               "abv",
    net_contents:      "net_contents",
    producer:          "producer",
    country_of_origin: "country_of_origin"
  }.freeze

  def self.call(app_data, extracted)
    field_results = FIELD_MAP.map do |app_key, extracted_key|
      app_value     = app_data[app_key.to_s].to_s
      label_value   = extracted[extracted_key].to_s
      match_result  = compare_field(app_value, label_value)

      {
        field:       app_key.to_s,
        app_value:   app_value,
        label_value: label_value,
        match:       match_result[:match],
        note:        match_result[:note]
      }
    end

    warning_result = compare_warning(extracted["government_warning"].to_s)

    verdict = determine_verdict(field_results, warning_result)

    {
      fields:             field_results,
      government_warning: warning_result,
      verdict:            verdict
    }
  end

  private

  def self.normalize(str)
    str.downcase.gsub(/[^\w\s\-\/]/, "").gsub(/\s+/, " ").strip
  end

  def self.compare_field(app_value, label_value)
    return { match: false, note: "Not found on label" } if label_value.blank?
    return { match: false, note: "Not provided in application" } if app_value.blank?

    n_app   = normalize(app_value)
    n_label = normalize(label_value)

    if n_app == n_label
      { match: true, note: nil }
    elsif n_app.include?(n_label) || n_label.include?(n_app)
      { match: "fuzzy", note: "Values are similar but not identical — review required" }
    else
      { match: false, note: "Application says \"#{app_value}\" but label shows \"#{label_value}\"" }
    end
  end

  def self.compare_warning(extracted_warning)
    normalized_extracted = extracted_warning.gsub(/\s+/, " ").strip
    normalized_required  = GOVERNMENT_WARNING.gsub(/\s+/, " ").strip

    present     = extracted_warning.present?
    exact_match = normalized_extracted == normalized_required
    has_prefix  = extracted_warning.start_with?("GOVERNMENT WARNING:")

    {
      present:     present,
      exact_match: exact_match,
      has_prefix:  has_prefix,
      note:        warning_note(present, exact_match, has_prefix, extracted_warning)
    }
  end

  def self.warning_note(present, exact_match, has_prefix, extracted)
    return "Government warning not found on label" unless present
    return "\"GOVERNMENT WARNING:\" prefix missing or not in all-caps" unless has_prefix
    return nil if exact_match
    "Warning text present but does not exactly match required TTB language"
  end

  def self.determine_verdict(field_results, warning_result)
    return "reject" unless warning_result[:exact_match]
    return "reject" if field_results.any? { |f| f[:match] == false }
    return "needs_review" if field_results.any? { |f| f[:match] == "fuzzy" }
    "approve"
  end
end
```

---

## Background Job

### `LabelAnalysisJob`

`app/jobs/label_analysis_job.rb`

```ruby
class LabelAnalysisJob < ApplicationJob
  queue_as :default

  def perform(label_review_id)
    review = LabelReview.find(label_review_id)
    review.update!(status: "processing")

    # 1. Get image path from Active Storage
    image_path = ActiveStorage::Blob.service.path_for(review.label_image.key)

    # 2. Extract fields via Ollama vision model
    extracted = OllamaService.call(image_path)

    # 3. Compare extracted fields against application data
    app_data = review.slice(
      "app_brand_name", "app_class_type", "app_abv",
      "app_net_contents", "app_producer", "app_country_of_origin"
    ).transform_keys { |k| k.sub("app_", "") }

    results = FieldComparator.call(app_data, extracted)

    # 4. Save results
    review.update!(
      extracted_fields: extracted.to_json,
      results:          results.to_json,
      verdict:          results[:verdict],
      status:           "complete"
    )

    # 5. Update batch counters if part of a batch
    if review.batch_upload_id
      batch = review.batch_upload
      batch.increment!(:completed_count)
      batch.update_status!
    end

  rescue OllamaService::ExtractionError => e
    review.update!(status: "failed", error_message: e.message)
    if review.batch_upload_id
      review.batch_upload.increment!(:failed_count)
      review.batch_upload.update_status!
    end
  end
end
```

### `BatchUpload#update_status!`

Add to the `BatchUpload` model:

```ruby
def update_status!
  if completed_count + failed_count >= total_count
    new_status = failed_count == total_count ? "failed" :
                 failed_count > 0 ? "partial" : "complete"
    update!(status: new_status)
  else
    update!(status: "processing")
  end
end
```

---

## Controllers

### `ReviewsController`

```
GET  /reviews/new       → new.html.erb  (single upload form)
POST /reviews           → create (upload image + app data, enqueue job, redirect to show)
GET  /reviews/:id       → show.html.erb (polls until status = complete|failed)
```

`create` action:
1. Build `LabelReview` with form params
2. Attach uploaded file to `label_image`
3. Save with `status: "pending"`
4. Enqueue `LabelAnalysisJob.perform_later(review.id)`
5. Redirect to `review_path(review)`

`show` action:
- Render review; view polls every 2 seconds via `<meta http-equiv="refresh">` until
  status is `complete` or `failed`

### `BatchesController`

```
GET  /batches           → index.html.erb  (all batches, auto-refresh)
GET  /batches/new       → new.html.erb    (batch upload form)
POST /batches           → create
GET  /batches/:id       → show.html.erb   (batch detail + per-label results)
```

`create` action:
1. Parse uploaded CSV (columns: `filename,brand_name,class_type,abv,net_contents,producer,country_of_origin`)
2. Match each CSV row to an uploaded image file by filename
3. Create one `BatchUpload` record
4. Create one `LabelReview` per row, associate with batch, attach image
5. Set `batch.total_count`
6. Enqueue `LabelAnalysisJob.perform_later(review.id)` for each
7. Redirect to `batch_path(batch)`

---

## Routes

```ruby
Rails.application.routes.draw do
  root "batches#index"

  resources :reviews, only: [:new, :create, :show]
  resources :batches, only: [:new, :create, :index, :show]
end
```

---

## Views

### Layout

- Plain HTML5 with a minimal CSS reset and system font stack
- No JavaScript framework required — only vanilla JS for the polling fallback
- Two nav links: "New Review" and "Batch Upload"
- No login, no sidebar, no modals

### Single Upload Form (`reviews/new.html.erb`)

Fields (in order):
1. Label Image (file input, accepts image/*)
2. Brand Name (text)
3. Class/Type (text, e.g. "Kentucky Straight Bourbon Whiskey")
4. Alcohol Content (text, e.g. "45% Alc./Vol. (90 Proof)")
5. Net Contents (text, e.g. "750 mL")
6. Producer Name & Address (text)
7. Country of Origin (text, optional)
8. Submit button: "Check Label"

### Single Review Results (`reviews/show.html.erb`)

If `status == "pending" || "processing"`:
- Show spinner + "Analyzing label…"
- `<meta http-equiv="refresh" content="2">` for auto-poll

If `status == "complete"`:
- Large verdict badge (green APPROVE / red REJECT / yellow NEEDS REVIEW)
- Uploaded label image thumbnail
- Results table (one row per field):
  - Field name
  - Application value
  - Extracted label value
  - Status icon (✓ / ~ / ✗)
  - Note (if any)
- Government Warning row at bottom, clearly marked as exact-match requirement
- "Back to Batch" link if part of a batch

If `status == "failed"`:
- Red error card with `error_message`

### Batch Upload Form (`batches/new.html.erb`)

Two inputs:
1. CSV file (instructions + downloadable template link)
2. Label images (multiple file input: `<input type="file" multiple accept="image/*">`)

CSV template columns:
`filename,brand_name,class_type,abv,net_contents,producer,country_of_origin`

Note displayed: "Upload the CSV and all image files at once. Filenames in the CSV must
match the uploaded image filenames exactly."

Submit button: "Upload Batch"

### Batch List (`batches/index.html.erb`)

Table with columns:
- Batch ID / Created At
- Status badge
- Progress (e.g. "47 / 200 complete")
- Failed count
- Link to batch detail

`<meta http-equiv="refresh" content="5">` — refreshes while any batch is in
`pending` or `processing` state; remove refresh once all are terminal.

### Batch Detail (`batches/show.html.erb`)

- Batch summary header (status, counts, created at)
- Table of all associated `LabelReview` records:
  - Row number / filename
  - Brand name (from app data)
  - Status badge
  - Verdict badge (if complete)
  - Link to full review

---

## Database Configuration

`config/database.yml`:

```yaml
default: &default
  adapter: sqlite3
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000

production:
  <<: *default
  database: /rails/storage/production.sqlite3
```

Enable WAL mode in `config/initializers/sqlite.rb`:

```ruby
ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(Module.new do
  def configure_connection
    super
    execute("PRAGMA journal_mode=WAL;")
    execute("PRAGMA synchronous=NORMAL;")
    execute("PRAGMA foreign_keys=ON;")
  end
end)
```

---

## Solid Queue Configuration

In `config/application.rb` (Rails 8 default, confirm it's set):

```ruby
config.active_job.queue_adapter = :solid_queue
```

In `config/solid_queue.yml`:

```yaml
production:
  workers:
    - queues: [default]
      threads: 3
      polling_interval: 1
```

---

## Dockerfile

Single container. Solid Queue runs inside Puma via `SOLID_QUEUE_IN_PUMA=1` — a
Rails 8 built-in that boots Solid Queue as a Puma plugin with no second process
required.

```dockerfile
FROM ruby:3.3-slim

# System dependencies
RUN apt-get update -qq && apt-get install -y \
  build-essential \
  libsqlite3-dev \
  libvips-dev \
  curl \
  git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /rails

# Gems
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test

# App code
COPY . .

# Precompile assets
RUN RAILS_ENV=production SECRET_KEY_BASE=placeholder bundle exec rails assets:precompile

# Storage and DB directories (will be volume-mounted in production)
RUN mkdir -p /rails/storage /rails/db

EXPOSE 3000

CMD ["sh", "-c", "bundle exec rails db:migrate && bundle exec rails server -b 0.0.0.0 -p 3000"]
```

---

## docker-compose.yml

```yaml
services:
  app:
    build: .
    ports:
      - "3000:3000"
    env_file:
      - .env
    volumes:
      - rails_storage:/rails/storage
    extra_hosts:
      - "host.docker.internal:host-gateway"   # Linux host resolution for Ollama
    restart: unless-stopped

volumes:
  rails_storage:
```

The `extra_hosts` entry is required on Linux so `host.docker.internal` resolves to
the host where Ollama is running. On Mac/Windows Docker Desktop this is automatic.

---

## .env.example

```
OLLAMA_URL=http://host.docker.internal:11434
OLLAMA_MODEL=gemma3:12b
RAILS_ENV=production
SECRET_KEY_BASE=
RAILS_LOG_TO_STDOUT=true
RAILS_MAX_THREADS=5
SOLID_QUEUE_IN_PUMA=1
```

---

## Migrations

### `CreateBatchUploads`

```ruby
create_table :batch_uploads do |t|
  t.string  :status,          default: "pending", null: false
  t.integer :total_count,     default: 0,         null: false
  t.integer :completed_count, default: 0,         null: false
  t.integer :failed_count,    default: 0,         null: false
  t.timestamps
end
```

### `CreateLabelReviews`

```ruby
create_table :label_reviews do |t|
  t.references :batch_upload, null: true, foreign_key: true

  t.string :status, default: "pending", null: false

  # Application data
  t.string :app_brand_name
  t.string :app_class_type
  t.string :app_abv
  t.string :app_net_contents
  t.string :app_producer
  t.string :app_country_of_origin

  # Output
  t.text   :extracted_fields
  t.text   :results
  t.string :verdict
  t.text   :error_message

  t.timestamps
end

add_index :label_reviews, :status
add_index :label_reviews, :batch_upload_id
```

---

## README Sections to Include

1. **Prerequisites** — Docker + Docker Compose, Ollama running on host with model pulled
2. **Quick Start** — `cp .env.example .env`, fill in `SECRET_KEY_BASE`, `docker compose up`
3. **Pulling the Ollama model** — `ollama pull gemma3:12b`
4. **Batch CSV format** — column list + downloadable template
5. **Known limitations** — heavily stylized fonts, very low resolution images, Ollama cold start latency
6. **Swapping models** — change `OLLAMA_MODEL` in `.env` and restart; any Ollama vision model works
7. **Linux Ollama networking** — explain `host.docker.internal` vs `extra_hosts`

---

## Implementation Order for the Coding Agent

1. `rails new ttb-label-verify --database=sqlite3 --skip-test` — scaffold
2. Add gems (`faraday`, `faraday-retry`), `bundle install`
3. Generate migrations, run `rails db:migrate`
4. Build `OllamaService` → test with the Python test script against a real label image
5. Build `FieldComparator`
6. Build `LabelAnalysisJob`
7. Build `ReviewsController` + views (single label flow end-to-end first)
8. Build `BatchesController` + views
9. Dockerfile + docker-compose
10. Smoke test: single label → batch of 3 → confirm jobs survive tab close
