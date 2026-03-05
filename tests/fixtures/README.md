Fixture Layout

This directory contains tiny sample source trees used to exercise scanners.

Rules:
- Fixtures are real code or config files, not mocks.
- Keep one primary behavior per fixture.
- Prefer tiny, readable inputs over mini-apps.
- Do not commit nested git repositories here.
- PR-style history should be generated in temporary repos during tests.

Structure:
- `tests/fixtures/<scope>/<scenario>/...`
- `tests/fixtures/manifest.json` describes the fixture class and expected assertion mode.

Fixture classes:
- `deterministic`: exact or near-exact scanner expectations are realistic.
- `bounded-drift`: upstream advisories or registries may change over time.
- `github-native`: used for workflow/report/permission behavior rather than source findings alone.
