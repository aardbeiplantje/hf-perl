# hf-perl

A Perl script for downloading files from Hugging Face with automatic retry and validation.

## Architecture

The script follows a simple three-phase process:

### Phase 1: URL Resolution
- Accepts `repo_id` (e.g., `gpt2`) or full URLs
- Constructs standard HF resolve URL: `https://huggingface.co/<repo>/resolve/main/<file>`
- Performs HEAD request to get CDN location from redirect headers
- Supports authenticated downloads via `HF_TOKEN` env var

### Phase 2: Download Loop  
- Up to 5 retry attempts for resilience
- Uses curl's `-C -` flag for automatic partial download resumption
- Logs HTTP headers to temp file for post-download validation
- Exponential backoff via `--retry 2 --retry-delay 2`

### Phase 3: Validation
- Reads Content-Length from header log
- Compares expected vs actual file size
- Retries on mismatch, exits on server errors (4xx/5xx)

## Key Design Decisions

**Why two curl invocations?** The HEAD check avoids downloading large files just to get the CDN URL. The actual download uses different options (`--progress-bar`, `--dump-header`).

**Retry strategy:** Non-server errors (network timeouts, etc.) trigger retries with resume. Server errors fail immediately.

**Validation approach:** Headers are captured in a temp file and parsed after download completes, avoiding complex signal handling during transfer.
