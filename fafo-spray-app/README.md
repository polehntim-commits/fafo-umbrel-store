# fafo-spray-app

Umbrel app listing for the Spray Compliance Module — the standalone
demonstration project defined in
[`spray_app_proposal.md`](../../spray_app_proposal.md).

This package wraps the Flask + SQLAlchemy server at
[`../../Spray_app/server/`](../../Spray_app/server/) as an Umbrel store
app so growers and packing houses can install the spray compliance
backend on their own Umbrel node in one click.

## What it provides

- A web front-end at the app's Umbrel URL (port `5056` on the host,
  `5055` inside the container) covering:
  - Public landing page listing seeded packing houses + invite codes
  - Grower self-registration (with optional packer invite code)
  - Packing-house self-registration (generates an invite code)
  - Grower onboarding — blocks, crop cycles, chemical inventory
    validated against the seeded pesticide reference registry
  - Grower and packer dashboards with live spray events and compliance
    alert feed
- A companion **iOS Progressive Web App** (PWA) — the web UI installs
  to the iPhone home screen with a custom icon and runs in
  standalone mode. A service worker caches the app shell so
  navigation works offline in the orchard.
- An embedded **NOSTR relay** on port `7447` so the companion SwiftUI
  field app can publish signed spray events over the farm network or
  via a Tor hidden service.
- Automatic **Tor hidden service** wiring via the `hooks/post-start`
  script — exposes both the HTTP front-end (port 80 → Flask) and the
  NOSTR relay (port 7447) on the app's `.onion` address.

## Building the image

From the Spray_app server directory:

```bash
cd ../../Spray_app/server
docker build -t polehntim/spray-app:v0.1.0-alpha .
docker push polehntim/spray-app:v0.1.0-alpha   # only needed for Umbrel install
```

For a quick smoke test without Umbrel:

```bash
docker run --rm -it \
    -p 5056:5055 -p 7447:7447 \
    -v spray_app_data:/data \
    polehntim/spray-app:v0.1.0-alpha
# Then open http://localhost:5056/ in a desktop browser or
# http://<umbrel-host-ip>:5056/ on an iPhone to install the PWA.
```

## Demo acceptance flow

Once the app is running, exercise the end-to-end validation loop from
proposal §2.5.3:

1. Open the app root — the landing page lists the seeded packers
   (`Columbia Gorge Packers` + `Yakima Valley Fresh`) and their invite
   codes (`GORGE123`, `YAKIMA42`).
2. Sign up as a grower, paste an invite code — the grower is linked to
   the packer immediately.
3. Add a block + crop (dropdown constrained by the reference registry).
4. Add a chemical inventory row (product dropdown constrained by
   seeded pesticides, warnings fire for unlabeled products).
5. From the companion iOS PWA or the SwiftUI app, POST a spray event
   to `/api/spray/events` or publish it over the NOSTR relay at
   `:7447`.
6. Refresh `/dashboard/grower` — the event appears with its
   compliance verdict; refresh `/dashboard/packer` — same event
   appears on the packer side within seconds.
7. Acknowledge any alerts from either dashboard — the loop closes.

## Files

| File | Purpose |
|---|---|
| `umbrel-app.yml` | Umbrel store manifest (id, name, port, description) |
| `docker-compose.yml` | Umbrel compose file wrapping `polehntim/spray-app` |
| `.env.app_proxy` | API and PWA asset paths whitelisted past Umbrel auth |
| `hooks/post-start` | Adds HiddenServicePort 7447 for iOS NOSTR access |
| `icon.png` | 1024×1024 app icon |
| `gallery/1.png…3.png` | Store-listing screenshots |
