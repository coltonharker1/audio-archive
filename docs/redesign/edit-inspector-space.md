# Edit inspector: freeing space at 900x692

Design by Codex `gpt-6.2-astra` (UI design role), Nov 25, 2026. Input: the 900x692 screenshot ~/.remanence-redesign/shots/after/11-edit-900.png, mock 04-edit.html, plan Phase 7-8 'Must still work'.

Make **Track actions ▾** a visible, full-row menu directly below the settings note. Put the three speed presets in the percentage menu and keep the 1% step buttons beside it. Those two changes leave room for the clipping warning, the masters sentence, and the pinned return button. The window footer can keep the mock’s wording.

One sizing detail matters: the current compact inspector is **230 pt wide**, with a 14 pt leading inset, so the screenshot has about **216 pt of usable width**. I’d design for that narrower width. The same layout works at the requested 260 pt without taking more space from the waveform. [LayoutSize](/Users/colton/code/me/macos/audio-archive/Remanence/DesignSystem.swift:113) · [Inspector](/Users/colton/code/me/macos/audio-archive/Remanence/EditView.swift:809)

### Inspector at 900 × 692

Heights include padding and hairline rules. The budget allows for a two-line track name and the longer clipping warning appearing together.

| Top to bottom | Height | Layout |
|---|---:|---|
| Selected track | 76 pt | Keep the mock’s small monospaced `TRACK 02 / SIDE A` eyebrow above the 21 pt serif name. Allow two title lines and retain the full-name tooltip. For an appended piece, use the existing `PIECE B1` form. |
| Level | 48 pt | First line has **Level** at left and the dB value flush right. Second line has the flexible slider and **Fit**. While measuring, the button reads **Measuring…** and disables itself. Keeping the value above leaves enough width for the longer button label. |
| Clipping warning, when present | 44 pt | Immediately under the slider, keep the existing triangle and exact or estimated warning text in the attention color. Allow three lines at 11 pt. Collapse this row completely when clear. |
| Speed | 32 pt | **Speed** at left, **− 100% ▾ +** at right. The buttons change speed by one percentage point. The percentage is a menu with **½×**, **1×**, and **2×**. It always displays the actual speed, including intermediate values such as `87%`. |
| Direction | 28 pt | Keep the mock’s **Direction** label and trailing **Forward ▾** or **Reversed ▾** picker. |
| Trim start | 26 pt | Keep **Trim start** at left and its read-only heard-time value at right, in hundredths. |
| Trim end | 26 pt | Same alignment for **Trim end**. Keep the two values on separate ruled rows so their digits line up as in the mock. |
| Settings or locked note | 60 pt | Keep the existing 12 pt sentence in full: “Level, speed and direction are heard here and applied when you push. Your masters never change.” On a locked tape, use the existing red locked explanation in this space. |
| Track actions ▾ | 34 pt | Use the mock’s 21 pt serif **Track actions** heading as the menu label, with a trailing chevron. Make the full row clickable and keyboard-focusable. |
| Flexible space | 8 pt minimum at the stated budget | Absorbs the space released by a short title, a shorter note, or an absent warning. |
| Drag hint | 46 pt | Hairline above the exact mock copy: “Drag between tracks to reorder. Drop onto a track to append its audio.” Allow up to three lines. |
| Return button | 42 pt | Pin the leading-aligned paper button at the foot, with room for the button and bottom inset. Keep the left arrow and **Return to Side A** title, or **Return to Review** for an unnamed recording. |

**Total: 462 pt of content + 8 pt of flexible space = 470 pt.** In SwiftUI, replace the compact inspector’s settings `ScrollView` with a `VStack(alignment: .leading, spacing: 0)`. Use intrinsic text heights within these budgets and `Spacer(minLength: 0)` immediately above the hint. Keep the hint and return button together at the bottom. Use `HairlineRule` at row boundaries and remove the current rule’s 16 pt padding on each side. These are design dimensions, not measurements from a rendered revision.

### Action reachability

| Entry point | Behavior to preserve |
|---|---|
| **Track actions ▾ → Join with previous…** | Keep `canJoin` eligibility and the existing confirmation naming the piece and explaining which settings it loses. Attach the dialog to the persistent row so it survives menu dismissal. |
| **Track actions ▾ → Append to another track… → target** | List the existing eligible targets by number and name. Choosing one uses the same `pendingAppend` confirmation and message as dropping onto a track. |
| **Track actions ▾ → Detach into its own track** | Show this command when an appended piece is selected. Selecting the indented piece makes it reachable directly. |
| **Track actions ▾ → Move up / Move down** | Give each direction its own menu item and retain its existing boundary check. Dropping between rows still reorders. |
| **Track actions ▾ → Reset trim / Reset level, speed and direction** | Put these two commands after a menu divider. Keep their independent enabled states so a level reset cannot also reset a trim. |

Keep **rename** on double-click of the name in the track list, with `endTyping()` on Return and Escape. Side renaming stays in **Side options → Rename Side…**, including for a single recording that has a side name. On a locked tape, disable all editing controls and mutation gestures, keep the red explanation legible, and leave Return available. With no selection, show **Select a track** and keep Return pinned. When the inspector is hidden, retain the existing settings or lock note below the close-up. [Edit view and track interactions](/Users/colton/code/me/macos/audio-archive/Remanence/EditView.swift:17) · [Side options](/Users/colton/code/me/macos/audio-archive/Remanence/TapeWorkspaceView.swift:204)

The mock’s left column stays intact: site-order rows, indented pieces and their combined duration, and the pinned close-up with its ruler, transport, zoom and Split controls. Scrubbing, trim handles, reversed and clipping waveforms, and playback through appended pieces keep their existing behavior. Return still takes the current piece and playhead back to Review at its previous zoom. The footer still reads **“Edits apply to playback and site copies · Master preserved.”** [Approved Edit mock](/Users/colton/code/me/macos/audio-archive/docs/redesign/04-edit.html) · [Edit and handoff plan](/Users/colton/code/me/macos/audio-archive/.build/redesign-logs/plan-phase7-8.md)