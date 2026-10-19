# DayPilot project conditions

Standing rules, set by the owner, that govern every change to this app.

## Text wrapping — no content may ever be cut off

Every text element in the UI must wrap rather than truncate. No ellipsis on
labels, buttons, prompts, errors, or report content. In practice:

- Text fields, labels, and error text use `lineLimit(nil)` and
  `fixedSize(horizontal: false, vertical: true)` so they grow instead of
  ellipsizing.
- Control rows (pickers, fields, buttons) wrap onto additional lines when the
  window narrows instead of compressing individual controls.
- Nothing may rely on a fixed width that could clip its text at any window
  size the app supports.

This was added after controls in the debrief view ellipsized at normal
window widths. Any future view is checked against it before it ships.

## Floating UI must never cover interactive content

Overlays (the Axo mascot, toasts, progress rings) live in their own reserved
space or container with the content; they do not float over controls, and
content does not scroll beneath them.
