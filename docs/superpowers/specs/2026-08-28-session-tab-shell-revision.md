# Session-tab shell revision

## Status

This revises the 2026-08-27 minimal canonical shell design after Michael's review. The core change of direction: the session-tab top bar stays and becomes the thing we invest in. There will be no single persistent native toolbar, and the top-bar layout is not being deleted.

Everything here is a proposal awaiting Michael's answers to the numbered decisions below. Implementation starts only after the chosen options are confirmed against rendered previews.

What survives from the 2026-08-27 spec unchanged: the action-inventory discipline (no action disappears without a tested new home), the accessibility contracts, the migration rules for the Files rail preferences, the recovery-language rules (no broker or reconnect wording in a healthy shell), and the performance rule that the shell renders from published summaries.

What is withdrawn: the single native toolbar, the removal of the top-bar layout, and the working-set tab switcher living inside a native toolbar.

## The two concrete defects driving this

1. The window corner rounding never shipped. `KaisolaVisualSystem.shellRadius` (30pt, the macOS 26 window neighbourhood) was added in v0.1.133 and is referenced by zero call sites. The window still shows the system corner.
2. The session tabs are the boxiest element in the app: 10pt `controlRadius` rectangles in a strip, while every surface around them moved to 14 to 26pt curves over the last month.

## Decision 1 — What the shell keeps

Options:

- (a) The session-tab top bar becomes the canonical shell. The left-tree layout is retired on the old spec's one-way-migration terms, and the top bar gets all the investment.
- (b) Both layouts stay, and only the top bar is redesigned. Every future shell change keeps paying the two-layouts tax the old spec documented.

Recommendation: (a). One shell to polish is the reason the old spec existed; the mistake was picking the wrong survivor.

## Decision 2 — One bar or two

Today the top-bar layout stacks a project strip above a session strip. Options:

- (a) Merge into one bar: a compact project switcher at the leading edge (current project name, menu for switching, matching the source-list popover), then the session tabs for the active project inline, then New Session and the overflow controls trailing. One band above the content, nothing else.
- (b) Keep two bands but restyle both.

Recommendation: (a). The old spec's own problem statement was the stack of bands; merging removes one permanently.

## Decision 3 — The tab design itself

The redesign direction for the session tabs, whichever bar structure wins:

- Pill tabs on the glass, `paneRadius` (14pt continuous) rather than capsules, so they rhyme with the pane cards below.
- The active tab is a white-led card (the shared bar surface material) with the existing soft shadow language; inactive tabs are quiet text on the glass with no resting fill, gaining a faint wash on hover.
- Status lives as the existing small activity mark before the title; attention keeps its dot. No badges collection.
- Close appears on hover and on the focused tab, using the surface-lifetime commands and confirmations from the old spec verbatim (Hide never stops work, End Session confirms, and so on).
- Tabs compress the way the old spec's switcher did: full titles while they fit, active keeps its title longest, then a count menu. The policy is pure and testable.
- Height moves from the current 36pt strip to a single 40pt bar so the tabs breathe.

Question for Michael: 14pt pills that match the pane cards, or full capsules like Safari's tab groups? A rendered preview of both is part of the confirmation step.

## Decision 4 — Window corners, for real this time

- (a) Apply `shellRadius` 30 as a true custom window shape: transparent titlebar, full-size content view, a clipped root container at 30pt with the matching window shadow. This is what "Apple-style edges" has asked for three times, and the token has been waiting since v0.1.133.
- (b) Keep the system window corner and only fix the interior corner ladder.

Recommendation: (a), with (b)'s ladder audit included either way. Risk to name honestly: custom window shapes interact with full screen, split view, and the traffic lights, so this ships behind its own fixture set.

## Decision 5 — The footer

The old spec dissolved the ConnectionFooter into menus. In the session-tab world the footer is also where the account chip and attention inbox live, and Michael uses that popover. Options:

- (a) Keep the footer, slimmed: account chip, usage percent, attention bell, ellipsis. Drop the connection status line from resting state (status appears only when something needs attention).
- (b) Remove it per the old spec and re-home everything into menus.

Recommendation: (a). The footer earns its row in daily use; only its plumbing language needed to go, and that already shipped.

## Decision 6 — The right side

The old spec's optional inspector (Files, Quick Look, Details in one card, no separate toolbar band) had no objections. Options:

- (a) Keep that part of the old design as-is, integrated under the new bar.
- (b) Leave the Files rail exactly as it is today and revisit later.

Recommendation: (a); it was the strongest part of the withdrawn spec.

## The confirmation process

1. Michael answers the six decisions (or edits them).
2. A preview fixture branch renders the chosen combination — real SwiftUI in the existing visual-fixture harness, light and dark, wide and narrow — and the screenshots come back for confirmation. Two tab-shape variants render side by side for Decision 3.
3. Only the confirmed previews get implemented, wave by wave, with the old spec's testing discipline (failing tests first, every removed action's new home proven).

## Rounding that does not wait

Independent of the shell decisions, two fixes proceed immediately because they are defects against already-made decisions, not new design:

- Apply the interior corner ladder audit so every chrome surface actually sits on its declared rung.
- The session-tab hover and selection fills move off `controlRadius` onto the shape chosen in Decision 3 the moment it is confirmed.
