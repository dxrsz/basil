# Lamar's Groceries 🐈‍⬛

Shared grocery lists that know what's for dinner. Flutter (iOS + Android) on Supabase, with OpenAI behind Supabase Edge Functions.

## What it does

- **Lists, shared live.** Have as many lists as you like and invite people with a 6-character code. Everyone sees adds, check-offs and removals in real time, and checked items show who got them.
- **Invite links.** Sharing sends `https://lamarsgroceries.app/join/CODE`; it opens the app if installed (App Links / Universal Links) or the web app otherwise, signs you in if needed, and drops you into the list.
- **Who's shopping now.** Small avatars show who else has the list open, and "Sam is at the store 🛒" when someone's shopping.
- **Push notifications.** "Sam is at the store — anything to add?", "Alex added 3 things to Weekly groceries" (bundled, never one per item) and "Kit joined your list", with per-kind switches and per-list mutes.
- **Smart list entry.** Type `2 lb chicken thighs` and it's stored as *Chicken thighs · 2 lb*, filed under the right aisle (Produce, Meat, Pantry…).
- **Meals.** A meal is just a name ("Taco bowls") and the items you associate with it. One tap puts its ingredients on the list, and items are tagged with the meal(s) they came from.
- **"Got this already?"** Before a meal's ingredients go on the list, a quick review pre-marks pantry staples (oil, salt, spices, rice…) and anything the household said it has as *Got it*. Answers are remembered per list for 30 days (or forever, if pinned); see and edit them under *Pantry staples* in the list menu. Every meal-adding screen goes through `showAddMealToListFlow` (`lib/features/pantry/add_meal_flow.dart`).
- **No duplicates.** Adding "avocados" when "Avocado · 2" is on the list bumps it to 3; compatible quantities add up ("2 cups" + "1 cup" → "3 cups"), others sit side by side ("1 bunch + 2"). Meals merge the same way, and a merged item remembers every meal it came from.
- **Tidy up.** The *Tidy up* wand on the shopping list asks Lamar to look over the list and propose merges of near-duplicates ("Chicken" + "Chicken thighs"), combined quantities and obvious fixes. You accept or reject each one; nothing changes until you apply.
- **"Forgetting rice?"** While you build a meal, the model reviews it. Likely-missing core ingredients show up as warning cards you can accept or dismiss, and nice-to-haves show up as chips. Dismissed ideas don't come back.
- **Auto-fill.** Name a meal and tap *Fill in ingredients* to get a starter list.
- **Snap or paste to add.** Photograph a handwritten list, a recipe card or the inside of the fridge, or paste a recipe link or a list. Lamar works out which it is and pulls out the items (or the meal and its ingredients). You review and edit everything before it's added. Recipe links are read from the page's schema.org Recipe data when it has some.
- **Store mode.** *I'm at the store* on the shopping tab opens a big, one-handed checklist grouped by aisle. Tap anywhere on a row and it slides into the cart (tap it there, or Undo, to put it back); the screen stays awake, and when the last thing is in, Lamar dances.
- **Works offline.** Lists, items, meals and members are cached on the device, so the app opens and the list works with no signal. Item changes (add, check, edit, remove, clear) apply at once, wait in a persistent outbox, and replay in order when you're back; a banner says when you're offline and when everything has synced. Meals and AI features ask for a connection.
- **Meal photos.** After saving, an image of the finished dish is generated from the actual ingredients. It regenerates only when the ingredients meaningfully change, and it reaches every device via realtime.

## AI features

- **Plan my week** (Meals tab): a one-time kitchen profile (diet, allergies,
  effort, appliances, tastes), then one meal card per night with keep / swap /
  nudge. Plans reuse perishables across the week; allergies and diets are
  enforced server-side (`plan-meals`, `safety.ts`). Photos are generated only
  for kept meals. Meal memory (👍/👎, "make again") feeds future plans.
- **What can I make tonight?** from what you have or recently bought.
- **Got this already?** before a meal's ingredients go on the list (pantry
  staples remembered per list), merge-on-add, and AI **Tidy up**.
- **Snap or paste**: photos of lists, recipe cards or the fridge, recipe links
  and pasted text, always reviewed before adding (`import-items`).
- **Store mode** and **offline** list editing with a sync queue.

## Layout

```
lib/
  data/          repository (all Supabase I/O) + Riverpod providers (realtime streams)
  features/      auth, lists (home), list (shopping + meals tabs, sharing), recipe (editor + detail)
  models/, util/ (aisle categorisation + quantity parsing), widgets/
supabase/
  migrations/    schema, RLS, RPCs, realtime publication, storage bucket
  functions/     suggest-ingredients, generate-recipe-image, import-items, tidy-list (OpenAI; key never ships in the app)
  tests/         Node tests for edge-function helpers: `node --test supabase/tests/` (Node 23+)
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
supabase functions deploy import-items
supabase functions deploy tidy-list
```

Optional secrets: `OPENAI_TEXT_MODEL` (default `gpt-5-mini`), `OPENAI_VISION_MODEL` (default `gpt-5-mini`; must accept image input), `OPENAI_IMAGE_MODEL` (default `gpt-image-1`) and `OPENAI_REASONING_EFFORT` (default `minimal`).

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

## Sharing: invite links, presence, push

### Invite links

`https://lamarsgroceries.app/join/<CODE>` (and `lamarsgroceries://join/<CODE>` as a
fallback). On the web, `/join/:code` is a normal route; signed-out visitors sign in
first and then continue. In the apps, `app_links` routes the link (cold start or
while running); Flutter's own deep linking is off (`flutter_deeplinking_enabled` /
`FlutterDeepLinkingEnabled`) so it doesn't fight `go_router` or the OAuth callback.

`web/.well-known/` is deployed with the web app (`vercel.json` keeps it out of the
SPA rewrite and serves it as JSON):

- **Android** (`assetlinks.json`): lists the SHA-256 of the local *debug* keystore
  (release builds are currently signed with it too). When a real release key (or
  Play App Signing) exists, add its fingerprint to `sha256_cert_fingerprints`
  (Play Console → App integrity, or `keytool -list -v -keystore <release.jks>`).
  Check with `adb shell pm verify-app-links --re-verify com.lamarsgroceries.app`
  then `adb shell pm get-app-links com.lamarsgroceries.app`.
- **iOS** (`apple-app-site-association`): replace `TEAMID_PLACEHOLDER` (twice) with
  the Apple Team ID once the developer account is active. The Runner target's
  `Runner/Runner.entitlements` has `applinks:lamarsgroceries.app` and
  `aps-environment`; device builds need a provisioning profile with Associated
  Domains and Push Notifications (automatic signing adds them once a team is set).
  Simulator builds don't need either.

### Presence

Each open list joins the private Realtime channel `presence:list:<list id>`.
Realtime Authorization policies on `realtime.messages` only let list members
receive or track presence there (`20261005140000_list_presence_auth.sql`).
Opening store mode (`isInStoreModeProvider`) marks you as shopping; anything
else can use `ref.read(shoppingNowProvider.notifier).setShopping(listId, true)`
(and `false` on leaving). Starting to shop also pings the others (at most once
per person per list per 30 minutes).

### Push notifications (Firebase Cloud Messaging)

How it works: database triggers queue events (`notification_outbox`, and
`item_add_batches`, which folds a person's adds into one notification sent 60 s
after their last add, or 5 min after the first). The `notify` edge function
claims due events and sends them through the FCM HTTP v1 API. It is called by
`pg_net` (immediately for joins/shopping, and from a 30 s `pg_cron` job when a
batch is due) with a random shared secret kept in `private.notify_config`, so it
runs with `verify_jwt = false`. Events are only queued if another member has a
registered device. Without `FCM_SERVICE_ACCOUNT` the function logs and returns
200 without sending.

The app builds and runs without any Firebase files (push is simply off; the
Google Services Gradle plugin is only applied when `google-services.json`
exists). To turn push on:

1. [Firebase console](https://console.firebase.google.com) → **Add project** (Analytics optional).
2. **Add app → Android**, package `com.lamarsgroceries.app`. Download
   `google-services.json` to `android/app/google-services.json`.
3. **Add app → iOS**, bundle ID `com.lamarsgroceries.app`. Download
   `GoogleService-Info.plist`, then in Xcode drag it into `Runner/` (target
   *Runner* checked, so it's in *Copy Bundle Resources*).
4. Once the Apple account is active: Apple Developer → Keys → **+** → *Apple Push
   Notifications service (APNs)*, download the `.p8`; Firebase → Project
   settings → Cloud Messaging → *Apple app configuration* → upload it with the
   Key ID and Team ID. Set the team in Xcode (Runner → Signing & Capabilities).
5. Project settings → **Service accounts → Generate new private key**, then:
   ```bash
   supabase secrets set FCM_SERVICE_ACCOUNT="$(cat path/to/service-account.json)"
   ```
   (Delete the downloaded key afterwards; it can send to all your users.)
6. Decide whether to commit the two config files (they're not secret, but are
   project-specific); add them to `.gitignore` otherwise.

The permission prompt appears after you join or share a list (or turn
notifications on in *Notifications* settings), never at first launch.

Deploying the backend: `supabase db push` and `supabase functions deploy notify`.
For a project other than the dev one, point the trigger at it:
`update private.notify_config set function_url = 'https://<ref>.supabase.co/functions/v1/notify';`

## Rate limits

Every OpenAI-backed edge function calls `consumeQuota(user, kind)` before
calling OpenAI. Limits live in `public.ai_limits` (one row per kind: burst
window/max, per-user daily, global daily, and the messages shown in Lamar's
voice). Over a limit, the function returns 429 and never calls OpenAI.
Edit limits in Supabase → Table Editor → `ai_limits`; `global_per_day = 0`
turns a feature off. New AI features add a row (and a `QuotaKind` in
`supabase/functions/_shared/clients.ts`). Also set a monthly budget on the
OpenAI project as a final backstop.

## Notes

- Never put the service-role key in the app or `env.json`. Edge functions receive it automatically from Supabase.
- `import-items` fetches user-supplied recipe links server-side through an SSRF guard (`import-items/safe_fetch.ts`): http/https on default ports only, every resolved address and every redirect hop must be public, 8 s timeout, 2 MB cap, HTML/JSON only. Photos are sent inline (base64) and never stored. `tool/import_items_e2e.mjs` exercises it against the live project with a throwaway user.
- Generated images live in a public-read bucket under random UUID paths. Only the edge function writes to it.
- Offline: `liveRows` takes an optional cache (`lib/data/offline/kv_store.dart`), and item writes go through `Outbox` (`lib/data/offline/outbox.dart`), which overlays queued changes on the server rows. Replays are idempotent (inserts ignore duplicates; updates/deletes by id never resurrect an item someone else removed; Clear only deletes the items that were checked, if they still are). `dart run tool/offline_check.dart` checks it end to end against the linked project with throwaway users.
- `isInStoreModeProvider(listId)` (`lib/features/store/store_mode.dart`) is true while someone is in store mode, for "shopping now" presence.
- `util/categories.dart` mirrors `public.categorize_item` in SQL; keep them in sync.
- `util/item_merge.dart` mirrors `public.normalize_item_name` / `public.combine_quantities`; both are checked against `test/fixtures/item_merge_cases.json` (`flutter test`, and `dart run tool/pantry_tidy_check.dart` against the linked project).
