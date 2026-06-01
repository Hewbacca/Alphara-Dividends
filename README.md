# Alphara Dividends

A minimal iOS app that tracks dividend announcements for a user-managed watchlist of
ticker symbols. It resolves tickers to company names, monitors each company for newly
announced dividends, fires a local notification when one appears, and shows an
"Upcoming" list with company, ex-dividend date, payment date, and amount.

A dividend stays in the **Upcoming** list until it has actually been **paid** — i.e. while
its payment date (or, if none is published, its ex-date) is today or later. So a dividend
that has already gone ex-dividend but hasn't paid yet still shows. The list is sorted by
soonest payment date first.

Each dividend shows how it compares to the company's previous **same-cadence** payment:
**unchanged** (default color), **increased** (green ↑), or **cut** (red ↓), with **New**
for anything lacking a comparable prior (first dividend, or only one-time specials, which
are excluded from the comparison). Notifications include the same wording (e.g. "increased
from $0.25"). The baseline comes from Polygon's per-ticker history in the same response we
already fetch — no extra API calls and no separately stored history.

Rows are tinted by date status: **green** when the dividend pays today, **blue** when it goes
ex-dividend today (dates compared in UTC). On the pay date, a separate **"paid today"**
notification fires (independent of the announcement alert) — at most once per dividend per
day (`DividendEvent.lastPaydayNotifiedOn`), and multiple dividends paying the same day are
combined into one notification (stable `payday-{date}` identifier). This payday scan is
network-free and runs on launch, on foreground, and in the background.

## Architecture

- **SwiftUI + SwiftData**, iOS 17+.
- **Data source:** [Polygon.io](https://polygon.io) free tier, behind a `DividendDataSource`
  protocol so the provider (or a future server-backed push model) can be swapped without
  touching the UI.
  - Ticker search: `GET /v3/reference/tickers?search=` → ticker + company name.
  - Dividends: **one small request per ticker**
    `GET /v3/reference/dividends?ticker={t}&order=desc&sort=ex_dividend_date&limit=8`,
    keeping records where `(payDate ?? exDate) >= today`. Per-ticker is reliable: the
    dividends endpoint has no multi-ticker filter, and a market-wide scan gets truncated by
    Polygon's huge, month-clustered universe (which previously dropped real watchlist tickers
    like V/TGT). To stay fast under the free tier's 5 req/min, a normal sync only re-checks
    **stale** tickers (`TrackedCompany.lastCheckedAt` older than ~6h); **Settings → Refresh
    all now** forces a full pass. Calls are paced by the shared limiter and results save
    incrementally, so the list fills in progressively.
- **Background monitoring:** `BGAppRefreshTask` (id `com.alphara.dividends.refresh`) runs
  the same sync engine as foreground refresh and fires **local** notifications for new
  events. New events are deduped by Polygon's stable dividend `id`. Background runs honor a
  **Wi-Fi-only** preference (Settings) and are skipped on cellular when enabled.
- **API key:** entered in Settings, stored in the **Keychain**. No shared key is embedded
  in the binary — each user supplies their own free Polygon key.
- **Watchlist persistence:** SwiftData persists locally across app *updates*; the watchlist
  is additionally mirrored to **iCloud key-value storage** (`NSUbiquitousKeyValueStore`) so
  it survives *reinstalls* and appears on the user's other devices. Requires the iCloud
  **Key-value storage** capability (see Build & run).

### Source layout
```
AlpharaDividends/
  AlpharaDividendsApp.swift     App entry: SwiftData container, BG task registration, notif auth, iCloud restore
  Models/                       TrackedCompany, DividendEvent (@Model)
  Services/                     PolygonClient, DividendSyncService, BackgroundRefreshManager,
                                NotificationManager, RateLimiter, KeychainStore, DividendDataSource,
                                NetworkMonitor, AppSettings, WatchlistBackup
  Views/                        RootView, UpcomingDividendsView, WatchlistView, AddTickerView, SettingsView
AlpharaDividendsTests/          DividendSyncService dedupe / detection / coverage tests
```

## Build & run

This repo uses [XcodeGen](https://github.com/yonwh/XcodeGen) to generate the Xcode
project from `project.yml` (keeps the repo free of a hand-edited `.pbxproj`).

```bash
brew install xcodegen          # one-time
xcodegen generate              # creates AlpharaDividends.xcodeproj
open AlpharaDividends.xcodeproj
```

Then in Xcode: select the `AlpharaDividends` scheme, choose an iOS 17+ Simulator or your
device, and Run. (Building/running requires full **Xcode**, not just Command Line Tools.)

> **Re-run `xcodegen generate` after pulling changes** that add files (XcodeGen uses
> explicit file references, so new sources/assets won't appear in the project otherwise).

**Signing / capability:** set your Team for signing, and enable the **iCloud → Key-value
storage** capability for the app target (the `com.apple.developer.ubiquity-kvstore-identifier`
entitlement is already in `AlpharaDividends.entitlements`). Without it the app still runs;
the watchlist just won't back up to iCloud. The icon, background modes, and notifications
need no extra setup.

### First-time setup in the app
1. **Settings → Polygon API key:** paste a free key from
   [polygon.io](https://polygon.io/dashboard/signup) and Save.
2. **Allow notifications** when prompted (or enable later in Settings).
3. **Watchlist → +:** search for companies (e.g. `AAPL`, `Apple`, `KO`) and add them.
4. **Upcoming:** pull-to-refresh (or Settings → Refresh now) to fetch dividends.

## Testing the background task
While the app is paused in the Xcode debugger, run:
```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.alphara.dividends.refresh"]
```
This forces a background-refresh run so you can verify sync + notifications.

Run unit tests with `Cmd-U` (or `xcodebuild test -scheme AlpharaDividends`).

## Known limitations (by design)
- **Background timing is best-effort.** `BGAppRefreshTask` is scheduled by iOS at its
  discretion — typically a few times a day, never while the app is force-quit, and
  user-disableable. **Foreground pull-to-refresh is the reliable path.** True real-time
  push would require a server + APNs (intentionally out of scope for this on-device build).
- **Polygon free tier:** 5 requests/minute and end-of-day data, so a freshly announced
  dividend can take up to ~a day to surface, and large watchlists refresh slowly because
  dividend calls are throttled ~12.5s apart during background sync.
