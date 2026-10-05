# Lamar's Groceries 🐈‍⬛

Shared grocery lists that know what's for dinner. Flutter (iOS + Android) on Supabase, with OpenAI behind Supabase Edge Functions.

## What it does

- **Lists, shared live.** Have as many lists as you like and invite people with a 6-character code. Everyone sees adds, check-offs and removals in real time, and checked items show who got them.
- **Smart list entry.** Type `2 lb chicken thighs` and it's stored as *Chicken thighs · 2 lb*, filed under the right aisle (Produce, Meat, Pantry…).
- **Meals.** A meal is just a name ("Taco bowls") and the items you associate with it. One tap puts its ingredients on the list, skipping anything already there, and items are tagged with the meal they came from.
- **"Forgetting rice?"** While you build a meal, the model reviews it. Likely-missing core ingredients show up as warning cards you can accept or dismiss, and nice-to-haves show up as chips. Dismissed ideas don't come back.
- **Auto-fill.** Name a meal and tap *Fill in ingredients* to get a starter list.
- **Meal photos.** After saving, an image of the finished dish is generated from the actual ingredients. It regenerates only when the ingredients meaningfully change, and it reaches every device via realtime.

## Layout

```
lib/
  data/          repository (all Supabase I/O) + Riverpod providers (realtime streams)
  features/      auth, lists (home), list (shopping + meals tabs, sharing), recipe (editor + detail)
  models/, util/ (aisle categorisation + quantity parsing), widgets/
supabase/
  migrations/    schema, RLS, RPCs, realtime publication, storage bucket
  functions/     suggest-ingredients, generate-recipe-image (OpenAI; key never ships in the app)
```

## Setup

### 1. Supabase project

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push
supabase secrets set OPENAI_API_KEY=sk-...
supabase functions deploy suggest-ingredients
supabase functions deploy generate-recipe-image
```

Optional secrets: `OPENAI_TEXT_MODEL` (default `gpt-5-mini`), `OPENAI_IMAGE_MODEL` (default `gpt-image-1`) and `OPENAI_REASONING_EFFORT` (default `minimal`).

### 2. OAuth

In **Dashboard → Authentication → URL Configuration**, add `lamarsgroceries://login-callback` to *Redirect URLs*.

In **Authentication → Providers**, enable:

- **Google:** create a *Web* OAuth client in Google Cloud and paste its client ID and secret. The authorised redirect URI is `https://<ref>.supabase.co/auth/v1/callback`.
- **Apple** (required on iOS when offering Google): create a Services ID plus a Sign in with Apple key, and use the same callback URL.

### 3. Run the app

Copy `env.example.json` to `env.json` (gitignored) and fill in your project URL and publishable key, then:

```bash
flutter run --dart-define-from-file=env.json
```

### Local development

```bash
cp supabase/.env.example supabase/.env   # add OPENAI_API_KEY + OAuth creds
supabase start
supabase functions serve --env-file supabase/.env
```

## Web (Vercel)

The web build deploys to Vercel straight from GitHub; `vercel.json` points
Vercel at `tool/vercel/install.sh` (fetches a pinned Flutter SDK, since
Vercel's image has none) and `tool/vercel/build.sh` (`flutter build web`).

1. Vercel → **Add New → Project** → import this repo. Leave Framework as
   "Other"; build settings come from `vercel.json`.
2. **Settings → Environment Variables**: `SUPABASE_URL` and
   `SUPABASE_PUBLISHABLE_KEY` (both public; never the service-role key).
3. **Settings → Domains**: add `lamarsgroceries.app`.
4. Supabase → Auth → URL Configuration: Site URL `https://lamarsgroceries.app`,
   and add it (plus `https://*-<team>.vercel.app/**` for previews) to Redirect URLs.

Pushes to `main` deploy to production; pull requests get preview URLs.
Builds take ~2 minutes (verified in an Amazon Linux 2023 container, the
image Vercel builds on).

## Rate limits

The OpenAI-backed functions are limited per user (`public.consume_ai_quota`):
suggestions 40 per 10 minutes / 300 per day, images 8 per hour / 30 per day.
Over the limit, the function returns 429 with a friendly message and never
calls OpenAI.

There's also a global daily cap across all users (`public.ai_global_limits`:
3000 suggestions, 300 images), a kill switch that bounds spend however many
accounts exist. Change it in Supabase → Table Editor → `ai_global_limits`;
set `per_day` to 0 to turn a feature off. Also set a monthly budget on the OpenAI project as a backstop.

## Notes

- Never put the service-role key in the app or `env.json`. Edge functions receive it automatically from Supabase.
- Generated images live in a public-read bucket under random UUID paths. Only the edge function writes to it.
- `util/categories.dart` mirrors `public.categorize_item` in SQL; keep them in sync.
