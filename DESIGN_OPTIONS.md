# Workbench design alternatives

All three alternatives use the same MoonBit core, actual poster sample and controls. Switch with the header selector or `?design=studio`, `?design=gallery`, `?design=clarity`. These are implementations guided by the listed skills; the skills do not prescribe these exact visual identities.

## ui-design — studio

Source used: the locally installed ui-design SKILL.md and its Product UI, Aesthetic Direction, Ideas, Colors, Typography, Form Controls, Navigation, Surfaces and Responsive references.

Priorities: a dominant work surface, predictable three-column navigation, 4px spacing, muted contextual chrome, consistent row anatomy and one primary save action. Inter Variable plus Chinese system fallback. Tokens include #202325, #292d30, #313639, #eef0f1, #aeb5ba and #8ec8bd. Layout is a quiet layer rail, central canvas and fixed-width inspector. The previous stacked collapse buttons are replaced with one row per layer, thumbnail, metadata and visibility control.

The comparison selector is local to preserve offline operation. It performs the variant-selection job without injecting the remote ui.sh toolbar.

## Anthropic frontend-design — gallery

Source: https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md

Priorities: the real work leads the first view, typography has an intentional identity, structural devices carry meaning, restrained decoration. Instrument Serif for the product wordmark, Inter Variable and Chinese system fallback for controls. Tokens include #ffffff, #f5f5f1, #e8ebe5, #26362e, #5c6c62 and #2b5b47. Layout removes the left rail and presents layers as a bottom contact sheet. A right inspector remains available for actual editing.

## UI/UX Pro Max — clarity

Source: https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/blob/main/.claude/skills/ui-ux-pro-max/SKILL.md

The skill's search tool returned Minimalism & Swiss Style for the explicit style query `minimalism swiss professional tool`. Its general design-system query also returned marketing hero patterns, which do not fit an editing workspace. The applicable style and accessibility rules guide this version.

Priorities: functional grids, high contrast, clear forms, keyboard focus, minimal decoration and native controls. Work Sans plus Chinese system fallback. Tokens include #ffffff, #f1f4f8, #172a42, #52657b, #1e5387 and #e6eef7. Layout uses a broad left canvas and one right task rail, with layer selection above the property editor.

## Layer semantics

The source NASA/JPL poster is one image layer. The added Chinese title, subtitle, rule and credit are four separate PNG layers within one group. X/Y, dragging and opacity apply to the selected whole layer. A design element is individually movable when it has its own layer. Renaming a layer changes its document name, not the wording painted into its pixels.

Controls support selection, visibility, renaming, integer movement, opacity, blend operation, sibling reordering, removal, original comparison, PNG export and ORA export. Moving groups is disabled because OpenRaster group offsets do not move their children. Every alternative exposes the same real operations.
