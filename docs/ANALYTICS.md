# Anonymous analytics

Loam counts launches on its own [Umami](https://umami.is) server (`pulse.personalize.design`): no third party, no
cookie, no identifier.

- **What is sent**: one `app_launch` event, two minutes after the app starts: Loam's version and build, the macOS
  version (`26.0`) and the system language. The server derives a country from the request's IP address and does not
  store the address. Never a note, a file name or a vault path.
- **On by default**, off with Settings > About > Send anonymous analytics. The choice is read when the event is
  about to go out, so turning it off during the first launch's intro is enough. Stored as `sendAnonymousAnalytics`
  in `UserDefaults`.
- **Release builds only**: `scripts/build-app.sh` writes `LoamAnalyticsURL` and `LoamAnalyticsWebsiteID` to Info.plist
  when `LOAM_RELEASE=1`. A development build or a test run has neither, so it sends nothing
  (`LOAM_ANALYTICS_URL` and `LOAM_ANALYTICS_WEBSITE_ID` point a release at another server).
- **Where it lives**: `App/Sources/NotebookApp/Analytics/AppAnalytics.swift`; tests in `AppAnalyticsTests`.
- **Server side**: Umami runs in the `analytics` namespace on vps-prod. The site `Loam — app (macOS)` takes these
  events, `Loam — landing` takes the website's page views (`loam.getpawtrait.com`).
- The agent string is browser-shaped (`Mozilla/5.0 … Loam/<version>`): Umami answers `{"beep":"boop"}` and drops the
  event when it takes the client for a bot.

The website (`landing-page-loam`) has the same box in its cookie banner, and says so in its Privacy Policy.
