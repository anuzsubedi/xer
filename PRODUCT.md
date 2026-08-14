# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Users

Apple-platform developers working on a Mac who repeatedly need to build one Xcode project and launch it on the local Mac, simulators, and connected physical devices without managing separate Xcode run destinations one at a time.

## Product Purpose

xer discovers Xcode projects and workspaces, lets the developer choose a shared scheme and multiple ready destinations—including This Mac—then builds, installs when needed, launches, and streams the resulting activity in one focused workspace.

## Positioning

The product turns a multi-destination Xcode build-and-launch workflow into one trusted, observable run operation while continuing to use Apple developer tools as the source of truth.

## Operating Context

xer is a native SwiftUI utility used alongside Xcode, Simulator, connected iPhones, and Finder. Users work with imported parent folders, Xcode containers, shared schemes, destination readiness, build diagnostics, and live application output.

## Capabilities and Constraints

- Projects must be explicitly trusted before xer invokes xcodebuild or project-defined build phases.
- Scheme discovery, destination discovery, search, multi-destination selection, build/install/launch, cancellation, and console filtering are existing product capabilities.
- The current implementation runs at most two selected destinations in parallel.
- Native macOS conventions, keyboard access, resizable layouts, and light/dark appearance must remain intact.

## Brand Commitments

The product name is “xer.” The interface should take inspiration from the Codex desktop app's calm hierarchy and native restraint without copying OpenAI branding or logos.

## Evidence on Hand

The repository contains the working product model, persistence, Xcode tooling integration, project icon discovery, and the complete SwiftUI surface. No customer claims, benchmarks, or marketing evidence should be invented.

## Product Principles

- Keep the current project and next run action obvious.
- Show readiness and risk before allowing execution.
- Keep diagnostics attached to the operation that produced them.
- Favor repeatable keyboard-efficient native workflows over decorative UI.
- Use Apple developer tooling without executing untrusted project code prematurely.

## Accessibility & Inclusion

Preserve VoiceOver labels, keyboard shortcuts, semantic status communication, scalable system typography, and system appearance contrast.
