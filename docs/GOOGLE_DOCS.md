# Google Docs: capability-based AX support, not yet live-verified

## Diagnosis and scope

Aure originally required the focused element's `AXValue`. It treated
`AXEditableAncestor` as a boolean hint instead of reading that editing target.
That supports many Gmail contenteditables but is insufficient for editors that
only expose text through `AXNumberOfCharacters` + `AXStringForRange`.

Google Docs uses canvas rendering rather than a conventional HTML text field:
https://workspaceupdates.googleblog.com/2021/05/Google-Docs-Canvas-Based-Rendering-Update.html
Google separately documents enabling screen-reader support:
https://support.google.com/docs/answer/6282736?hl=en
Neither statement proves that a particular Chrome/Docs version supplies the
complete, writable macOS AX text interface Aure needs.

The probe in this environment returned `NOT TRUSTED`; no live Chrome/Docs AX
snapshot was available. No personal document was read or edited. Unit tests
exercise synthetic AX capability inputs, not a captured Docs fixture. **Do not
advertise this patch as verified end-to-end Google Docs support.**

## Changes

- Resolve the explicit `AXEditableAncestor` (same process, secure fields rejected),
  without scraping arbitrary document children or unrelated page content.
- If AXValue is missing or its length conflicts with the advertised character
  count, try AXStringForRange for the complete zero-based range. Require exact
  UTF-16 length agreement; cap this fallback at 100,000 UTF-16 units. No selected
  text, live-region announcements, clipboard copy, or truncated window is treated
  as a complete document.
- Replacement requires unchanged text, a currently focused target, valid UTF-16
  boundaries, and a verified AX selection. No unverified Command-A fallback.
  AX/paste results are read back; uncertain writes are not retried automatically.
  A successful API call alone is not reported as a verified replacement.
- Diagnostic output contains roles, capabilities and offsets, not document text,
  titles, descriptions, or URLs. Optional text measurement prints only lengths.

## User-assisted, non-personal reproduction

1. Open a **disposable** Google Doc in Chrome and type a synthetic paragraph such
   as `This are a test sentence for Aure.` Do not use an existing personal doc.
2. Confirm Aure has macOS Accessibility permission. The shell probe needs a
   separate permission for its terminal/runner; grant that only if you choose.
   The script never grants permission or bypasses TCC.
3. From the repository, run the following and focus the test paragraph during
   the wait. It changes no text and sends no keystrokes:

   ```sh
   swift scripts/ax-probe.swift com.google.Chrome --wait 8 --enable-tree --measure-text
   ```

4. In **Docs > Tools > Accessibility (or Accessibility settings)**, check **Turn
   on screen reader support**. macOS shortcut: **Command + Option + Z** (a toggle;
   prefer the checkbox to verify the state). This is separate from granting
   Aure macOS permission or enabling Chrome's AX tree. Aure does not toggle the
   user's Docs accessibility settings automatically.
5. Repeat the probe after refocusing the synthetic paragraph. Compare the
   focused/explicit-editable target's AXValue availability and length, character
   count, AXStringForRange support/result, and selection writability.
6. With the built Aure app, confirm a bubble appears for this test paragraph,
   apply one correction only in this disposable document, and inspect the actual
   paragraph and Undo history. This manual step has **not** been performed here.
   Also regression-test Gmail in a disposable unsent draft.

If both modes expose only an empty input proxy, announcements, text markers, or
an incomplete text window, this AX implementation still cannot safely check and
replace the document. Stop there: don't auto-copy the selection, scrape canvas
labels into a fake field, or select-all/paste. A separately designed browser /
Google Workspace integration is needed. A generic contenteditable extension is
not automatically a Docs solution; its editor integration and offset/write
contract must be verified. Google recommends supported Workspace APIs/add-ons.

## UI integration handoff

No UI files are changed by this work. `TextReplacer.replace` now returns nil for
unverified replacement; callers must surface failure rather than dismissing the
suggestion as applied. A future capability/status affordance should explain
that some document editors do not expose readable/writable text and link to the
Docs setup above, without claiming that enabling the setting guarantees support.
