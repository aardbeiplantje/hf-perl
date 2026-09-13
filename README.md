# hf-perl

A simple Perl script to download files from Hugging Face.

## Usage

```bash
./hf.pl <repo_id> <filename> [target_dir]
```

Examples:

```bash
./hf.pl gpt2 gpt2.bin ./models
./hf.pl https://huggingface.co/gpt2/blob/main/gpt2.bin
```

Set `HF_TOKEN` environment variable for authenticated downloads.
