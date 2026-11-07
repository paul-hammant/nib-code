---
status: accepted
date: 2026-11-06
---

# Images: attach by path or clipboard, store by reference, `view` separate from `read`

**Decision:** Support png, jpeg, gif and webp in two ways that share one storage and encoding layer: the user attaches images in the TUI, and the model looks at files with `tools.view(path)`.

## Entry points

Terminals cannot paste image bytes, so the TUI has two zero-dependency entry points. Pasted text that is a path to an existing image file (quoted, `file://`, or with escaped spaces, as drag-and-drop produces) attaches the file instead of inserting text. Ctrl+V reads the system clipboard through `osascript` (macOS), `wl-paste` or `xclip` (Linux); with no tool or no image it shows a short notice. Each image is an atomic `[Image #N]` editor block numbered with paste blocks. Images are refused with a notice when the model has no vision.

## Stored by reference

Each image is copied into `<session>.images/` under a content-hash name (files 0600). Messages and the Session log hold references (path, media type, size, dimensions), never base64; requests read and encode the file on demand. A missing file on resume becomes a text placeholder, so a log stays valid after its images are cleaned up. Dimensions come from file headers; there is no decoding library and no resizing, so images over 5 MB (Anthropic's per-image limit) are rejected with a clear message instead of being shrunk.

## `view` is separate from `read`

`read` returns complete UTF-8 text to JS and its data must round-trip through `read → write`. An image has no such use in JS, so `view` returns only metadata and attaches the pixels to the Run's tool result for the next request. This keeps `read` semantics unchanged, keeps images out of the 16 KiB text display budget (capped at 4 per Run instead), and lets `{ ok: false, error }` report a model without vision as data. No prompt rule encourages screenshots; the tool description alone introduces it.

## Wire encodings and capability

Each protocol uses its native image part ([providers.md](../providers.md#images)). Tool results are the difficult case: Anthropic accepts images inside `tool_result`; Codex/OpenAI Responses accept `input_image` items in the tool output array; other Responses services and Chat Completions get a user message with the image right after the tool output(s), because tool messages there cannot carry images. Vision is a property of the provider/model table (false for Chat Completions defaults and DeepSeek) that custom providers set with `vision = true|false`. Compaction summarizes old images as `[image name W×H omitted]` and estimates 1500 tokens per image.

## Not done

No `nib ask` image input, no resizing or re-encoding, no image generation, and no images from background Runs.
