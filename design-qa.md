# Design QA

## Inputs

- Dialog action reference: `/var/folders/nf/x_h1szcj38nf_x58j_03p0n40000gp/T/codex-clipboard-7f8aaa72-9a2e-45e4-9d4a-b2803cf39e68.png`
- Action sheet reference: `/var/folders/nf/x_h1szcj38nf_x58j_03p0n40000gp/T/codex-clipboard-a99d7bac-3655-456a-be18-9ef57f509c01.png`
- Implementation viewport: macOS desktop, 1200 × 768 app content pixels.
- Compared states: resting, pointer hover, desktop width, and bottom-sheet presentation.

## Comparison

- Dialog actions retain the original two-cell layout; hover now fills the complete action cell and clips to the dialog's outer corner.
- Theme and language menus retain the original Apple-style grouped action sheet with full-width rows, separators, and a detached cancel group; glass is applied to the surfaces only.
- Desktop action sheets are centered and capped at 840 logical pixels; compact layouts remain edge-to-edge.
- Progress sheets remain bottom-presented with rounded top corners, a centered 720-pixel desktop width, and a full-width bottom action hover area.

## Evidence

- Action sheet comparison: `/tmp/whisper-qa.HltJCj/action-sheet-comparison.png`
- Dialog hover comparison: `/tmp/whisper-qa.HltJCj/dialog-hover-comparison.png`
- Final action sheet: `/var/folders/nf/x_h1szcj38nf_x58j_03p0n40000gp/T/com.openai.sky.CUAService/whisper Screenshot 2026-09-01 at 9.28.12 PM.jpeg`
- Final dialog hover: `/var/folders/nf/x_h1szcj38nf_x58j_03p0n40000gp/T/com.openai.sky.CUAService/whisper Screenshot 2026-09-01 at 9.28.36 PM.jpeg`
- Final progress hover: `/var/folders/nf/x_h1szcj38nf_x58j_03p0n40000gp/T/com.openai.sky.CUAService/whisper Screenshot 2026-09-01 at 9.33.36 PM.jpeg`

## Result

Passed after restoring the original menu structure, narrowing the desktop surface, and replacing pill/rectangular hover artifacts with boundary-aware full-cell highlights.
