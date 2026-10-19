import Foundation

/// The sample Day Brief behind "Load a sample Day Brief".
///
/// A report is the product, and a new install has none until a workday has been
/// recorded end to end. This gives the library something to open on day one:
/// written to disk, it stops being a fixture and becomes an ordinary report —
/// listed in the sidebar, editable, and deletable like any other, which is also
/// how the welcome screen comes back.
///
/// It is written to the standard the app asks for: the copy an expert commercial
/// editor would sign off on. Sentence-case sections, no icons, no stage numbers
/// or nicknames, every claim carrying a number or a name, the brief itself well
/// under 450 words — and the session record kept under `### Provenance`, where
/// the report view hides it behind **Session Info** rather than putting it on
/// the page.
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
    # Day Brief — Monday, 12 October 2026

    ## The day in brief

    Eight hours and twenty eight minutes on the report library and the window tabs, both landed, build clean throughout. The provider layer was rewritten without one request against a live key, so every clean build since is unverified against the real API.

    ## Where the time went

    - Xcode — 3h 45m
    - Terminal — 22m
    - Safari — 18m of passive tabs, nothing moved

    ## What moved

    - `ReportLibrary` now reads every archived `.md` from the folder itself, so a debrief written before the database knew about it still opens.
    - The top bar became a three tab switcher — Library, Memory, Settings — behind one window.
    - Reports render through the same host the app runs, which is what reproduced the blank window.

    ## Open threads

    - `APIClient.swift` resolves every provider through one path, and no request has gone through it since the rewrite.

    ## Recovered fragments

    ```text
    grep -rn "TODO" Sources/ | head -20
    ```

    ## Worth remembering

    - A view only fails where the user sees it: hosting the report the way the app hosts it reproduced the blank window on the first try.

    ## Tomorrow, first move

    Add a provider key in Settings, then run one short session against the live provider before touching the catalogue again.

    ### Provenance

    - **Session:** `session_2026-10-12T09-12-04Z_SAMPLE0001`
    - **Duration:** 8h 28m
    - **Events captured:** 142 (9 ephemeral)
    - **Frames suppressed by the privacy shield:** 0
    - **Synthesised with:** Sample content, written so a Day Brief is there to read before a real session has been recorded
    - **Generated:** 2026-10-12T17:40:31Z

    ### Added to your working profile

    - One session against a live API is worth more than another hour of reading its code.
    - Bind the width instead of asking a text view for its ideal height.
    """
}
