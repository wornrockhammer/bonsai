# 16 — Token Limit Fix (Truncated AI Output)

> **Status:** Ready to implement
> **Severity:** High — this is the 4th time token limits have broken features
> **Scope:** Single file change
> **File:** `webapp/src/app/api/generate-title/route.ts`

---

## Problem

Voice-to-text ticket descriptions are being truncated mid-sentence. The browser's Web Speech API captures the full transcript correctly, but the post-processing "massage" step cuts the text short.

**Symptom:** A spoken ticket description gets cut off at "so that we" — the text simply ends with no error shown to the user.

## Root Cause

`/api/generate-title` calls Gemini 2.5 Flash with per-field `maxOutputTokens` values. The `massage` field (used by voice input) is capped at **2048 tokens**. When the model's response reaches that ceiling, it stops generating — producing truncated output.

Current per-field token limits:

| Field | `tokens` | Purpose |
|---|---|---|
| `title` | 1024 | Generate short ticket title (max 8 words) |
| `criteria` | 2048 | Generate acceptance criteria checklist |
| `enhance` | 2048 | Fix typos/grammar without changing length |
| `massage` | 2048 | Fix typos/spelling/formatting (voice input) |
| `massage_criteria` | 2048 | Convert voice transcript to criteria checklist |

## Key Insight

`maxOutputTokens` is a **ceiling**, not a cost lever. The model stops on its own when finished — you are only charged for tokens actually generated. A 50-word response costs the same whether `maxOutputTokens` is 2048 or 65536. The parameter exists to prevent runaway generation, not to save money. Setting it too low silently truncates output with no warning.

## Affected Code Path

```
User clicks Voice button
  → voice-button.tsx renders mic UI
  → useVoiceInput hook starts webkitSpeechRecognition
  → Browser captures real-time transcript
  → On stop: processTranscript() called
  → fetch("/api/generate-title", { field: "massage" })
  → Gemini 2.5 Flash processes text
  → maxOutputTokens: 2048 ← TRUNCATION HAPPENS HERE
  → Cleaned text returned to form field (cut off)
```

### Voice input consumers

- `webapp/src/app/new-ticket/page.tsx` — description (`massage`) and criteria (`massage_criteria`)
- `webapp/src/components/board/ticket-detail-modal.tsx` — description, criteria, and comments

### Files in the pipeline

| File | Role |
|---|---|
| `webapp/src/components/voice-button.tsx` | UI component |
| `webapp/src/hooks/use-voice-input.ts` | Hook: speech capture + AI cleanup call |
| `webapp/src/app/api/generate-title/route.ts` | API route: Gemini call with token limit |

## Codebase Audit

Only **one file** in the entire codebase sets `maxOutputTokens`:

```
webapp/src/app/api/generate-title/route.ts:52
  generationConfig: { maxOutputTokens: config.tokens },
```

Other Gemini routes (`generate-worker`, `avatar`) do **not** set `maxOutputTokens` and have no truncation issues. The `transcribe` route uses OpenAI Whisper which has no configurable token limit.

---

## Implementation Plan

### Step 1 — Add shared constant

At the top of `route.ts`, add:

```ts
const MAX_OUTPUT_TOKENS = 65536;
```

65536 is Gemini 2.5 Flash's maximum output token limit.

### Step 2 — Remove per-field `tokens` values

Change the prompts type from:

```ts
const prompts: Record<string, { text: string; tokens: number }> = {
```

To:

```ts
const prompts: Record<string, { text: string }> = {
```

Remove every `tokens: NNNN` line from each prompt entry.

### Step 3 — Use the shared constant

Replace line 52:

```ts
generationConfig: { maxOutputTokens: config.tokens },
```

With:

```ts
generationConfig: { maxOutputTokens: MAX_OUTPUT_TOKENS },
```

### Result

One constant controls the ceiling for all fields. If Gemini's max changes, update one number. No per-field tuning needed — the model stops on its own when done.

---

## Verification

1. Run dev server
2. New ticket page → Voice button → record 3+ sentence description
3. Confirm full massaged text appears without truncation
4. Test title generation still produces short titles
5. Test criteria generation still produces checklists
6. Test enhance still fixes typos without rewriting
