# Changelog

## 1.0.0-dev.9 — 2026-10-06

- Mark Profile Action Bars as partial when optional pet or form bars are configured outside its ordinary-button scope.

## 1.0.0-dev.8 — 2026-10-06

- Explain that toggling action-bar titles, key labels or counts also changes the recording setup.

## 1.0.0-dev.7 — 2026-10-06

- Explain that changing action-bar columns or spacing also changes the recording setup.

## 1.0.0-dev.6 — 2026-10-06

- Explain that moving or scaling any action bar changes the recording setup; finish layout editing before a comparison.

## 1.0.0-dev.5 — 2026-10-06

- Include initialized custom action bars in Profile Action Bars, keeping disabled bars' zero counters in exports.
- Record custom-bar state and mark configuration or target changes during a recording as partial coverage.

## 1.0.0-dev.4 — 2026-10-06

- Add Profile Action Bars to measure its event handler and native cooldown callbacks with all scoped counters retained in exports.
- Record initial/final bar state and capture limits; install measurement hooks only during recording and restore them at Stop.

## 1.0.0-dev.3 — 2026-10-05

- Keep the standalone Profiler, Settings and Live Monitor in the shared window order.

## 1.0.0-dev.2 — 2026-10-05

- Organize standalone Settings under Profile and Profiler using the shared library.
- Use the distinct Profiler navigation icon when integrated into Suite.

## 1.0.0-dev.1 — 2026-10-05

- Development prerelease for the independent Booty product distribution; BootyLib is required.

- Add a standalone Profiler window, minimap menu and settings with optional Booty Suite integration.
- Share the BootyLib interface while preserving callback, early-login, health and export behavior.
- Keep Profile All independent of the selected Booty diagnostic scope and protect reload during active product work.
- Preserve Live Monitor geometry when loading legacy settings profiles; resets retain recording exports and login reports.
