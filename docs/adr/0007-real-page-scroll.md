# ADR 0007: Scrolling is real browser scrolling

- Status: Accepted
- Date: 2026-07-21

## Context

Replacing document scrolling with camera movement would bypass sticky elements, lazy loading, listeners, CSS effects, and intermediate page state.

## Decision

`scrollTo` dispatches controlled, timed real browser scrolling and records timestamped scroll-position samples. Author input supports either a semantic target or coordinates, never both.

## Consequences

The application experiences genuine scroll state. The compositor may smooth visual framing but camera movement never substitutes for document scrolling.
