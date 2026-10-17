import Foundation

/// Fixture content for `--render-previews`, which draws the windows offline.
///
/// These are representative sample values for layout and visual review. They are
/// never written to disk and never used by the running app.
enum PreviewFixtures {

    static let sessions: [StoredSession] = [
        StoredSession(
            id: "session_2026-10-12T09-12-04Z_A1B2C3D4",
            startedAt: "2026-10-12T09:12:04Z",
            stoppedAt: "2026-10-12T17:40:31Z",
            eventCount: 142,
            breadcrumbCount: 9
        ),
        StoredSession(
            id: "session_2026-10-11T10-03-20Z_E5F6A7B8",
            startedAt: "2026-10-11T10:03:20Z",
            stoppedAt: "2026-10-11T16:21:09Z",
            eventCount: 97,
            breadcrumbCount: 4
        ),
        StoredSession(
            id: "session_2026-10-10T08-55-41Z_C9D0E1F2",
            startedAt: "2026-10-10T08:55:41Z",
            stoppedAt: "2026-10-10T12:02:17Z",
            eventCount: 51,
            breadcrumbCount: 2
        )
    ]

    static let debrief = """
    # Day Brief — Monday, 12 October 2026

    ## The day in brief

    A focused morning in Xcode: the windowed shell became real — session library, report editor, and full Settings, alongside the menu bar item. The open thread is the provider catalogue, which has not been run against a live key since the refactor.

    ## Where the time went

    - Xcode — 3h 45m
    - Terminal — 22m
    - Safari — 18m, mostly passive

    ## What moved

    - The windowed shell ships: `MainWindowView.swift`, `ReportEditorView.swift`, `SettingsView.swift`, `ModelCatalog.swift` — clean release build.
    - The provider layer was rewritten around a single resolve path in `APIClient.swift`.

    ## Recovered fragments

    ```text
    Open on the meal photo, hard cut to the calorie card, one shake and one audio stutter. Hold for 0.8 seconds, then the headline.
    ```

    ## Worth remembering

    - Render interfaces through the same host the user runs: the blank window only reproduced when views were hosted the way the user sees them.

    ## Tomorrow, first move

    Add a key in Settings and run one short session against the live provider before touching the catalogue code again.
    """
}
