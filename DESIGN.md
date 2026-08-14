---
name: xer
description: A quiet native deployment workbench for Xcode projects and Apple devices.
colors:
  action-blue: "#3264E8"
  success-mint: "#34C759"
  warning-amber: "#FF9F0A"
  danger-red: "#FF3B30"
  graphite: "#1D1D1F"
  divider: "#0000001A"
typography:
  title:
    fontFamily: ".AppleSystemUIFont"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.2
  body:
    fontFamily: ".AppleSystemUIFont"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  label:
    fontFamily: ".AppleSystemUIFont"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1.2
  console:
    fontFamily: "SFMono-Regular"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.4
rounded:
  control: "7px"
  surface: "12px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "20px"
  xl: "28px"
---

# Design System: xer

## Overview

**Creative North Star: “The Quiet Runbook”**

xer should feel like a native instrument beside Xcode: calm enough to stay open all day, dense enough to make state obvious, and structured around one repeatable build route. Its hierarchy borrows the composure of the Codex desktop app—translucent navigation, restrained chrome, and one clear action—without borrowing identity.

**Key Characteristics:** three stable spatial zones, native materials, tool-grade rows, one blue action color, and persistent activity.

## Colors

System materials own the large surfaces so light and dark appearances remain native. Action Blue is reserved for selection, focus, and the Run action; semantic colors only report state.

**The One Command Rule.** Never distribute accent color decoratively. If no element is actionable or selected, it should usually be neutral.

## Typography

Use the macOS system face for all interface hierarchy and SF Mono for logs, identifiers, and commands. Titles are restrained rather than oversized; utility labels remain sentence case.

## Layout

The app uses a hideable 250-point project rail at left; when visible, it never resizes. On wide windows, the upper workspace splits build configuration from destinations while the console spans the lower workspace. Below 840 points of detail width, configuration and destinations stack into one scrolling workspace; the console remains vertically resizable below. Headers and toolbars progressively collapse before content clips. Each operational pane scrolls independently, and the window remains usable down to 760 points wide.

## Elevation & Depth

Depth comes from sidebar/bar materials, tonal surface changes, and one-pixel separators. Avoid floating-card shadows and ornamental blur.

## Shapes

Use 7-point continuous corners for controls and 12-point continuous corners for grouped operational surfaces. Pills are reserved for compact status, never general containers.

## Components

- **Project row:** app icon, name, container kind, and trust state; selection uses the native sidebar treatment.
- **Build configuration:** vertically ordered Scheme, Build Configuration, Actions, and Options groups with full-width controls and disciplined dividers.
- **Destination row:** checkbox, device glyph, two-line platform metadata, semantic readiness, and a full-width blue-tinted selected state.
- **Console pane:** a full-width lower workspace with a compact filter/search header above selectable monospaced output.
- **Run action:** the only prominent button; anchor it at the lower-right of the destinations pane and keep ⌘Return.

## Do's and Don'ts

- Do preserve native controls, system materials, resizability, keyboard access, and semantic state.
- Do keep activity visible during selection and execution.
- Don't turn the workspace into a dashboard of independent cards.
- Don't use gradients, neon glows, decorative glass, giant headings, or excessive pills.
- Don't copy OpenAI marks, names, or proprietary brand assets.
