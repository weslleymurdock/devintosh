# `scripts/lib/progress.ps1`

Provides the shared ANSI progress-bar implementation used by pipeline stages.

The library is presentation-only: it does not make configuration decisions or inspect hardware.

## Terminal rendering contract

The progress bar is rendered on a single in-place terminal row using the existing ANSI gradient and Unicode block characters. Before each redraw, the complete row is cleared with ANSI erase-line control so a shorter activity message cannot leave stale characters behind.

Normal console messages must not be concatenated onto the progress row. The shared console helpers clear the active row before writing step/result messages. This is important for regression testing because WARN and FAIL states must remain visible rather than being visually merged with a progress update.

The change is presentation-only and does not alter stage exit codes, rollback behavior, or pipeline decisions.
