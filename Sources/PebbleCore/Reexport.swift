// PebbleCore re-exports the portable deterministic core (PORTING module 01):
// every existing `import PebbleCore` keeps seeing the full API surface while
// PebbleCoreBase stays buildable on any Swift platform (no Apple frameworks).
@_exported import PebbleCoreBase
