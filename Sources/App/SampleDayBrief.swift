import Foundation

/// The sample Day Brief behind "Load a sample Day Brief".
///
/// A report is the product, and a new install has none until a workday has been
/// recorded end to end. This gives the library something to open on day one:
/// written to disk, it stops being a fixture and becomes an ordinary report —
/// listed in the sidebar, editable, and deletable like any other, which is also
/// how the welcome screen comes back.
///
/// Deliberately separate from `PreviewFixtures`, whose values never reach disk
/// because they exist only to draw windows offline.
enum SampleDayBrief {

    /// The encoded session id. It carries a real start time so the sidebar can
    /// read a date out of it, and it sorts below any session recorded after
    /// 12 October, so a day of the user's own always opens first.
    static let sessionId = "session_2026-10-12T09-12-04Z_SAMPLE0001"

    /// `<YYYY-MM-DD>_<sessionId>.md` — the shape `ReportLibrary` discovers.
    static var fileName: String { "2026-10-12_\(sessionId).md" }

    static let markdown = """
    # ⚡ Indie Velocity Debrief — 2026-10-12

    ### 1. 🚀 Shipped Velocity (The Needle Movers)
    - Landed the report library refactor — `ReportLibrary` now reads every archived `.md` from the folder itself, so a debrief written before the database knew about it still opens.
    - The top bar became a tab switcher — Library, Memory and Settings — so the whole app lives behind one window.

    ### 2. 🧲 Rescued Assets (The Harvester)
    - A line that kept bouncing between tabs all morning: *"render interfaces through the same host the user runs — the blank window only reproduced when views were hosted the way the user sees them."*
    - Scratch note, now a rule: bound the width instead of asking a text view for its ideal height.

    ### 3. ⏱️ The Reality Mirror
    - **Core Deep Work:** 3h 45m in Xcode.
    - **Productive Procrastination:** 18m of passive Safari tabs that moved nothing.
    - **Friction & Strategic Lesson:** The provider layer was rewritten without a single run against a live key. Every clean build since is unverified against the real API. One short session against the live provider beats another hour of reading the code.

    ### 4. 🎯 Tomorrow's Zero-Friction Launchpad
    - **Target File:** `DayPilot/Sources/Synthesis/APIClient.swift`
    - **Terminal Command:** `make selftest`
    - **First Micro-Action:** Add a key in Settings, then run one short session against the live provider before touching the catalogue again.

    ---

    ### Recovered fragment

    ```text
    grep -rn "TODO" Sources/ | head -20
    ```

    ### Provenance

    - **Session:** `session_2026-10-12T09-12-04Z_SAMPLE0001`
    - **Duration:** 8h 28m
    - **Events captured:** 142 (9 ephemeral)
    - **Frames suppressed by the privacy shield:** 0
    - **Synthesised with:** Sample content · written so a Day Brief is there to read before a real session has been recorded
    - **Generated:** 2026-10-12T17:40:31Z

    ### Voice script (spoken)

    > A sample brief, kept in the same shape as a real one so the layout matches what a workday produces.

    The day opened in Xcode and stayed there: three hours and forty five minutes on the report library and the main window tabs. Twenty two minutes in the terminal, eighteen minutes of passive browsing in Safari that moved nothing forward. The lesson is the one worth keeping — rewrite the provider layer, then prove it against a live key before calling it done. Tomorrow, start by adding a key in Settings and running one short session.

    ### Rules of thumb added to the user profile

    - One session against a live API is worth more than another hour of reading its code.
    """
}
