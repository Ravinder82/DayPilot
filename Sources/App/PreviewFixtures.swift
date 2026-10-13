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
    # ⚡ Indie Velocity Debrief — 2026-10-12

    ### 1. 🚀 Shipped Velocity (The Needle Movers)
    - **DayPilot:** the app now opens as a real window with a session library, a report editor and a full Settings window, alongside the menu bar item.
      - *Evidence:* `MainWindowView.swift`, `ReportEditorView.swift`, `SettingsView.swift`, `ModelCatalog.swift`, clean release build.
      - *Why it moves the needle:* the day's output is readable and editable where it is produced, which is where the next fix starts.

    ### 2. 🧲 Rescued Assets (The Harvester)
    - **Bundle: Pattern-interrupt hook for the launch video** — *Source fragments:* a Stickies note and an AI Studio prompt draft.
      - *Synthesized output:*
        ```text
        Open on the meal photo, hard cut to the calorie card, one shake and one audio stutter. Hold for 0.8 seconds, then the headline.
        ```
    - **Bundle: Model-agnostic debrief prompt** — *Source fragments:* a scratch note in Terminal.
      - *Synthesized output:*
        ```markdown
        Summarise this session as: what shipped, what leaked, and one rule of thumb.
        ```

    ### 3. ⏱️ The Reality Mirror
    - **Core Deep Work:** about four hours in Xcode on the provider and model code.
    - **Productive Procrastination:** roughly 35 minutes adjusting corner radii and sidebar widths that were already correct.
    - **Friction & Strategic Lesson:** the window was blank until its views were hosted the way the user sees them. Render interfaces through the same host the user runs.

    ### 4. 🎯 Tomorrow's Zero-Friction Launchpad
    - **Target File:** `Sources/App/AppModel.swift`
    - **Terminal Command:** `make install`
    - **First Micro-Action:** open the app from Launchpad, add a key in Settings, and run one short session before changing any code.
    """
}
