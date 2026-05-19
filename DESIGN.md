---
version: alpha
name: Whisper Design System
description: Design direction for the Whisper Flutter app and companion product site.
colors:
  primary: "#2563EB"
  primary-dark: "#7CA7FF"
  secondary: "#0EA5E9"
  connected: "#0284C7"
  trusted: "#16A34A"
  warning: "#D97706"
  danger: "#DC2626"
  surface: "#FFFFFF"
  surface-muted: "#E2E8F0"
  surface-canvas: "#F1F5F9"
  text: "#0F172A"
  text-muted: "#64748B"
  message-incoming: "#F8FAFC"
  message-outgoing: "#EFF6FF"
  dark-surface: "#000000"
  dark-surface-elevated: "#0A0A0A"
  dark-surface-muted: "#141414"
  dark-border: "#242424"
  dark-text: "#E2E8F0"
  dark-text-muted: "#8A8F98"
typography:
  screen-title:
    fontFamily: system
    fontSize: 28px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: 0em
  section-title:
    fontFamily: system
    fontSize: 20px
    fontWeight: 650
    lineHeight: 1.25
    letterSpacing: 0em
  body:
    fontFamily: system
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: 0em
  label:
    fontFamily: system
    fontSize: 13px
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: 0em
rounded:
  control: 16px
  list-item: 18px
  card: 24px
  pill: 999px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
components:
  primary-action:
    backgroundColor: "{colors.primary}"
    textColor: "#FFFFFF"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: 12px
  secondary-action:
    backgroundColor: "{colors.secondary}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: 12px
  status-chip:
    backgroundColor: "{colors.connected}"
    rounded: "{rounded.pill}"
    size: 10px
  trusted-chip:
    backgroundColor: "{colors.trusted}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: 8px
  warning-chip:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: 8px
  danger-chip:
    backgroundColor: "{colors.danger}"
    textColor: "#FFFFFF"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: 8px
  muted-panel:
    backgroundColor: "{colors.surface-muted}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: 16px
  muted-label:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-muted}"
    typography: "{typography.label}"
  canvas:
    backgroundColor: "{colors.surface-canvas}"
    textColor: "{colors.text}"
  conversation-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.card}"
    padding: 16px
  message-incoming:
    backgroundColor: "{colors.message-incoming}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: 12px
  message-outgoing:
    backgroundColor: "{colors.message-outgoing}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: 12px
  dark-primary-action:
    backgroundColor: "{colors.primary-dark}"
    textColor: "{colors.dark-surface}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: 12px
  dark-shell:
    backgroundColor: "{colors.dark-surface}"
    textColor: "{colors.dark-text}"
  dark-card:
    backgroundColor: "{colors.dark-surface-elevated}"
    textColor: "{colors.dark-text}"
    rounded: "{rounded.card}"
    padding: 16px
  dark-muted-panel:
    backgroundColor: "{colors.dark-surface-muted}"
    textColor: "{colors.dark-text-muted}"
    rounded: "{rounded.control}"
    padding: 16px
  dark-separator:
    backgroundColor: "{colors.dark-border}"
    textColor: "{colors.dark-text-muted}"
    height: 1px
---

# DESIGN.md

## Overview

Whisper should feel calm, local-first, and practical: a reliable chat-like workspace for moving files, text, audio, and input between nearby personal devices. The app UI is task-focused and should stay quiet enough for repeated daily use. The product site may be more editorial, but it should still show the real product and avoid exaggerated cloud/SaaS language because the core value is LAN-first collaboration.

## Colors

- Use blue as the primary action and connection color: `#2563EB` in light mode and `#7CA7FF` / `#38BDF8` accents in dark mode.
- Use green only for trust/success states, amber for warnings, and red for destructive or failed states.
- Keep large surfaces neutral: white and slate-tinted surfaces in light mode, true black and near-black layers in dark mode.
- Chat bubbles should remain subtle: incoming `#F8FAFC`, outgoing `#EFF6FF`, and low-contrast dark equivalents.
- Do not make new screens monochrome blue. Use semantic green, amber, red, and neutral surface layers to preserve scanability.

## Typography

Use the platform/system font stack through Flutter Material 3 and Tailwind/system fonts on the web. Keep hierarchy modest inside tool surfaces: screen titles can be prominent, but lists, chat rows, settings, transfer states, and controls should use compact readable text. Chinese, English, and Spanish strings must fit without clipping, so prefer flexible layouts over fixed-width labels.

## Layout

- Mobile uses a single-column flow: device discovery, conversation, transfer controls, and settings should each be easy to scan with one thumb.
- Desktop can use denser master-detail layouts, especially for device lists plus active conversation/workspace state.
- Keep repeated rows stable in height where possible so connection, transfer, and remote-input state changes do not shift the whole view.
- Use `16px` as the normal spacing unit, with `8px` for tight internal gaps and `24px` or `32px` for major groups.
- Product-site pages should keep the first viewport focused on Whisper itself, with real screenshots or app imagery visible early.

## Elevation And Depth

The app should rely on tonal surfaces and subtle borders more than shadows. Existing cards use large rounded corners and low/no elevation; preserve that unless a platform convention strongly suggests otherwise. Avoid heavy glass, blur, dramatic gradients, and decorative blobs in the app shell.

## Shapes

- Current Flutter controls use rounded inputs around `16px`, list items around `18px`, cards around `24px`, and status chips as pills.
- Icons should be familiar platform/material symbols where available.
- Keep chat bubbles, device rows, and status chips visually related; avoid introducing unrelated geometric styles within the same feature.

## Components

- Buttons: reserve the primary filled style for the main action in a view. Secondary actions should be tonal, outlined, icon-only, or text buttons depending on importance.
- Device rows: show name, platform, discovery/connection state, trust state, and recent activity without making the row feel like a marketing card.
- Chat composer: keep attachment/file actions, text entry, and send state reachable without crowding the input.
- Transfer progress: show file name, direction, progress, speed, and recoverable state clearly; failures need a visible retry or explanation when available.
- Remote input and audio controls: make role, active peer, and stop/release actions obvious because these features affect another device.
- Settings: group by user outcome, not implementation detail. Keep dangerous or privacy-sensitive toggles separated and clearly labeled.
- Web product sections: use the same blue/neutral palette, screenshots, concise feature blocks, and real capability language.

## Accessibility And Responsiveness

Maintain strong text contrast in both light and dark themes. Hit targets should remain comfortable on touch devices while desktop layouts may be denser. Do not rely on color alone for connection, trust, warning, or failure states. Check long localized strings, file names, device names, and IP addresses for overflow.

## Do's And Don'ts

- Do reuse `AppTheme` and `WhisperPalette` tokens before adding colors.
- Do keep LAN/privacy limitations honest in product copy.
- Do test both compact mobile and wider desktop layouts for UI changes.
- Do update ARB localization files for new user-facing strings.
- Don't introduce public-cloud or account-centric UI assumptions unless the product direction changes.
- Don't add decorative visuals that obscure real device, transfer, audio, or remote-input state.
- Don't hand-edit generated localization or Drift files.
