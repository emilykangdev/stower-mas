# Analytics (MAS)

## Why

Anonymous funnel analytics for the Mac app: enough to see how many people launch,
clear the hardware/license/messages-access gates, and reach the board — without
ever collecting anything that could identify a person or expose Messages data.
The whole subsystem lives in `Sources/StowerMacUI/Analytics/`.

On the MAS target, TelemetryDeck is **not available**. All analytics events are
routed through `StowerNoOpAnalyticsReporter`, which drops every event silently.
The typed event taxonomy (`StowerAnalyticsEvent`), consent infrastructure
(`StowerDiagnosticsConsent`), and the no-op reporting seam are retained so the
app target compiles without conditional compilation — but no signal ever leaves
the device.

## Identity (MAS: no-op)

`StowerDiagnosticsIdentity.clientUser()` returns a plain random per-install `UUID`,
minted once and persisted in `UserDefaults`. On MAS this identity is never
transmitted — the TelemetryDeck SDK is absent, so the UUID stays on device.

## Kill switch

Since the reporter is always `StowerNoOpAnalyticsReporter` on MAS, the consent
gate controls whether events are dropped at the reporting layer. The in-memory
`StowerDiagnosticsKillLatch` still provides immediate fail-closed behaviour when
the user opts out mid-session.

## Consent (default-on with disclosure, "off wins")

Analytics is **default-on**. `StowerDiagnosticsConsent.isEnabled` returns `true` when
no record exists yet (fresh install). The user is shown the
`StowerAnalyticsConsentCard` once, after ~60 seconds of foreground board time
— after they've seen value, never at startup or at the messages-access permission
cliff. One-click off lives in a Privacy pane (`StowerSettingsView` →
`StowerPrivacySettingsView`) in the app's `Settings { }` scene.

## Event taxonomy (typed, PII-safe)

`StowerAnalyticsEvent` is a typed enum; no case accepts a raw string that could carry
a message body, contact name, phone number, search query, or file path. Each case maps
to a `signalName` and a bucketed `parameters` dictionary.

| Event | Signal | Semantics |
|---|---|---|
| `appLaunched` | `app_launched` | per-launch |
| `sessionEnded` | `session_ended` | per-launch |
| `hardwareChecked(supported:reason:)` | `hardware_checked` | per-occurrence |
| `trialStarted` | `trial_started` | once per trial life |
| `paywallReached(error:)` | `paywall_reached` | per-occurrence |
| `checkoutOpened` | `checkout_opened` | per-occurrence |
| `activated` | `activated` | per-occurrence |
| `messagesAccessRequested` | `messages_access_requested` | per-run |
| `messagesAccessResolved(granted:)` | `messages_access_resolved` | per-run |
| `boardReached` | `board_reached` | per-launch |
| `boardItemClicked(itemType:)` | `board_item_clicked` | per-occurrence |
| `featureUsed(feature:surface:)` | `feature_used` | per-occurrence |
| `feedbackOpened(licenseStatus:)` | `feedback_opened` | per-occurrence |
| `feedbackSent(licenseStatus:)` | `feedback_sent` | per-occurrence |

## Reporting seam

`StowerAnalyticsReporting` is a synchronous, non-throwing, `Sendable` protocol.
On the MAS target, the only live conformer is `StowerNoOpAnalyticsReporter`
(drops every event). `StowerInMemoryAnalyticsReporter` (lock-guarded spy) is
available for tests.

## All signals are no-op

Because the TelemetryDeck SDK is absent from the MAS target, every analytics
signal is silently dropped. The consent infrastructure and event taxonomy are
retained for source compatibility with the non-MAS target and for future use
should a MAS-compatible analytics backend be added.
