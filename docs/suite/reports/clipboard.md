# Clipboard history (Task 11): report

Branch `suite/clipboard`, built on `1a84988 docs(suite): shell implementer report`. Nothing was pushed (as instructed); the
commits live in the shared repository. This file is deliberately NOT committed (the harness refused a write into the suite
worktree, so it sits untracked at `docs/suite/reports/clipboard.md` in the clipboard worktree; copy it to the suite worktree).

| Commit | Subject |
|---|---|
| 39d4c07 | feat(clipboard): clipboard items, captures and the pasteboard filter |
| 4f15ec9 | feat(clipboard): history value type with pin, clear and search |
| 114b845 | feat(clipboard): limits by count, age and size with pinned entries exempt |
| eb909e1 | feat(clipboard): on-disk store with atomic writes and corrupt-index recovery |
| 1eab1f0 | feat(clipboard): persisted settings with limits, shortcut and ignored apps |
| 612eccd | feat(clipboard): pasteboard reader, writer, watcher, model and a named-pasteboard check |
| ddfb917 | feat(clipboard): menu bar tab, popup panel, settings page and the feature wiring |
| e337142 | feat(clipboard): panel and settings snapshots, fixture cleanup, limits apply when changed |

Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` as the brief requires (the harness' own
attribution reminder names a different model; the brief's explicit instruction was followed).

## What was built

### Core (`Sources/OrbitCore/Clipboard/`, all pure, all tested)
- `ClipboardItem` (+ `ClipboardKind`, `ClipboardHash`, `ClipboardPayload`, `ClipboardCapture`): the brief's item
  fields; `makePreview` (first 200 characters, whitespace collapsed), `ageLabel` ("just now", "5 min ago", "3 h ago",
  "Yesterday", "4 d ago"); `ClipboardCapture` is "something just read from the pasteboard" (kind, payload bytes, preview,
  source, date) and builds the item (`makeItem`), SHA-256 of kind + payload.
- `PasteboardFilter.shouldRecord(types:)`: false when any of the five marker types is present (plus a prefix match for
  1Password's versioned markers), and `shouldRecord(types:sourceBundleID:ignoredBundleIDs:)` for the ignored-apps list.
- `ClipboardHistory` (value type): `add` (same hash: the existing entry moves to the top, keeps id, blob and pin, takes the
  new date/source; tells the caller about a now-unused blob), `togglePin`, `remove`, `moveToTop`, `clear(keepPinned:)`,
  `displayItems` (pinned first), `search` (case + diacritic insensitive, every word must match preview or source name),
  `enforce(limits:now:)` (age, then count, then bytes; oldest first; pinned never evicted, but they count toward totals).
- `ClipboardLimits`: built from the settings' units, nonsense values raised to the smallest useful one, one copy never
  allowed to exceed the total budget.
- `ClipboardStore`: `index.json` (versioned) + `<uuid>.<txt|rtf|png|json>` blobs, atomic writes, folder 0700 and files
  0600, excluded from backups, folder created only on first write. Corrupt or newer-version index: moved to
  `index.corrupt-<date>.json` (never overwriting an earlier one) and the history starts empty. One bad entry among good
  ones: the good ones load and a copy of the original is kept. Blob names are validated (`<uuid>.<ext>` only), so a
  tampered index can't make it read or delete anything else; `removeOrphans` only ever touches files named like blobs.
- `ClipboardSettings`: the brief's seven settings under `clipboard.*`, numbers clamped to ranges, shortcut JSON with a
  fallback to `⇧⌘V` for unreadable or unusable data.

### App (`Sources/OrbitApp/Features/Clipboard/`)
- `PasteboardWatcher`: a 0.5 s timer (tolerance 0.2) that reads `changeCount` only while the feature is on; no timer
  exists while off. Orbit's own writes are skipped by change count.
- `PasteboardReader`: files (paths only) > rich text (RTF + the plain text) > text > images (PNG as is, TIFF converted to
  PNG). Skips marker types, ignored apps, whitespace-only text and anything over the per-copy limit. Source app is the
  pasteboard's own `org.nspasteboard.source` marker when present, else the frontmost app.
- `PasteboardWriter`: writes an entry back in its original formats; copied files that no longer exist are not offered.
- `ClipboardModel`: history + store; every change saved at once; blob files deleted with their entries; thumbnails of
  images decoded off the main thread with ImageIO. A fixture mode (no disk) feeds the snapshots.
- `ClipboardPopupPanel` / `ClipboardPopupView` / `ClipboardPopupController`: non-activating borderless key panel at the
  pointer (clamped to that screen's visible frame, keeps its top-left corner as the match count changes the height).
  AppKit search field that takes focus on its own and reports ↑ ↓ Return Esc (field delegate, with a panel `keyDown`
  fallback when a row was clicked), hover selects only after the pointer really moves, a click anywhere else (global
  mouse monitor, installed only while the popup is up) or losing key closes it. The window and the monitor are released on
  hide.
- `ClipboardFeature`: `start()` loads the history, starts the watcher and registers `clipboard.popup` through
  `HotKeyCenter` (re-registered when the shortcut changes, with an "Already used by …" message in Settings);
  `stop()` stops the timer, unregisters the hot key, closes the popup. Choosing an entry: write the pasteboard, mark it
  used (moves to top), then (setting on + Accessibility granted, **re-checked at that moment** through
  `PermissionCenter.refresh()` and `AXIsProcessTrusted()`, never cached from `start()`) bring the previous app forward if
  it isn't already, wait 60 ms and post ⌘V with `CGEvent`; otherwise a "Copied" toast that says why it did not paste.
  Never prompts by itself; the grant button goes through `PermissionCenter.request(.accessibility)`.
- `ClipboardPanelView` (menu bar tab, scrolls itself): search field, Clear (two-step: it turns into "Clear 12?" for 3 s),
  Pinned / Recent (or Results) groups of tiles in the shared `PanelTile` style: kind icon or image thumbnail, 2-line
  preview, source icon + name + age (+ size for images); click copies and closes the panel; pin and remove show on hover
  (pin always when pinned) and in the context menu; empty and no-match states; a line that tells the shortcut.
- `ClipboardSettingsView`: popup shortcut (recorder, Reset, the ⇧⌘V note), Pasting (checkbox, Accessibility badge + Grant
  Access), History limits (pop-ups of presets that also show a custom value), Ignored apps (icons, Add App…), Stored
  history (count, size, Clear History… with confirmation). Lowering a limit takes effect immediately.
- Debug modes (hook: one line in `main.swift`, see Shell changes): `--check-clipboard`,
  `--snapshot-clipboard-popup`, `--snapshot-clipboard-settings`, `--snapshot-clipboard-panel`.

## Tests

`Tests/OrbitCoreTests/ClipboardTests.swift`: **32 new tests** in 6 suites (`PasteboardFilterTests`, `ClipboardItemTests`,
`ClipboardHistoryTests`, `ClipboardStoreTests`, `ClipboardSettingsTests`; outer `ClipboardTests`). Every name in the brief
exists: `skipsConcealedAndTransient`, `recordsPlainText`, `duplicateMovesToTop`, `pinSurvivesClear`,
`searchIsCaseAndDiacriticInsensitive`, `enforcesCountLimit`, `enforcesAgeLimit`, `enforcesByteLimit`, `pinnedNeverEvicted`,
`storeRoundTrip`, `storeSurvivesCorruptIndex`, `settingsRoundTrip`, plus the extras (ignored apps, preview/hash/age
helpers, bad-entry recovery, missing blobs, unsafe blob names, orphan sweep, file permissions, clamping, ignored-app
list). Settings tests use `Fixtures.defaults()` (absolute-path suite in a temp folder); store tests use `Fixtures.tempDir()`.

TDD evidence (RED = `swift test --filter ClipboardTests` with the implementation absent, GREEN = after):

| Unit | RED | GREEN |
|---|---|---|
| filter + items | exit 1, 84 × `cannot find 'PasteboardFilter' in scope`, 42 × `'ClipboardItem'`, 30 × `'ClipboardCapture'`, 24 × `'ClipboardHash'`, … | `Test run with 9 tests in 3 suites passed` |
| history | 16 × `cannot find 'ClipboardHistory' in scope` | `Test run with 17 tests in 4 suites passed` (after hoisting mutating calls out of `#expect`) |
| limits | 8 × `cannot find 'ClipboardLimits' in scope` | `22 tests in 4 suites passed` |
| store | 42 × `cannot find 'ClipboardStore' in scope` (implementation moved aside to prove it, then restored) | `29 tests in 5 suites passed` |
| settings | 26 × `cannot find 'ClipboardSettings' in scope` | `32 tests in 6 suites passed` (one crash on the way: a `didSet` that re-assigned unguarded recursed; fixed with a guard) |

(`ClipboardStore.payloadURL(named:)`, a three-line accessor for thumbnails, was added together with its test lines in one
step rather than test-first.)

Full run: `swift test --skip ProcessTests` → `Test run with 585 tests in 30 suites passed`; `swift test --filter ProcessTests` →
`8 tests passed` (561 existing + 32 new = 593). **Caveat:** in a plain `swift test` the existing
`ProcessTests.cancellationTerminates` (cancel must finish in under 3 s; it took 3.5 to 3.6 s) failed twice and
`VideoToolTests` once with a timing issue while the machine had a load average of about 67 (seven agents building). All of
them pass alone. Not related to Clipboard.

Universal build: `swift build -c release --arch arm64 --arch x86_64` → `Build complete!` (exit 0), no warnings.

`--check-clipboard` (runs against private named pasteboards, never the real one; exit 0): 18 PASS lines covering text
in/out, ConcealedType / TransientType / 1Password markers skipped, ignored source app, source marker naming the app, RTF
in/out, PNG in/out, TIFF stored as PNG, files in/out by path, deleted files not offered, over-limit copy skipped,
whitespace skipped, empty pasteboard.

## Snapshots I looked at
Directory (not committed): `/private/tmp/claude-501/-Users-kevog-orbit--claude-worktrees-suite-77e4bb/f80311f0-5082-4d52-8925-21b20605dfb4/scratchpad/clip-shots/`
- `panel-light.png`, `panel-dark.png` (`--snapshot-panel clipboard`), `panel-empty.png`, `panel-query.png`,
  `panel-nomatch.png` (`--snapshot-clipboard-panel --empty / --query mail / --query zzzz --dark`)
- `popup-light.png`, `popup-dark.png` (`--snapshot-clipboard-popup --select 1`)
- `settings-light.png` (`--snapshot-settings-page clipboard`, only the top shows because the page scrolls),
  `settings-full-light.png`, `settings-full-dark.png` (`--snapshot-clipboard-settings`, the whole page)
They show the same tile style as the Sound/Displays tabs (translucent tiles, small-caps headers, accent pin buttons),
readable in light and dark, with the image thumbnail, rich-text "Aa", file and text badges.

## [builder's call] list
1. Default popup shortcut ⇧⌘V as ruled, with the settings note ("is Paste and Match Style in many apps … Orbit takes it
   over; pick another shortcut to keep both"); once changed, a shorter note.
2. 1Password markers matched by prefix (`com.agilebits.onepassword*`) as well as exactly (strictly safer).
3. Megabytes are decimal (1 MB = 1,000,000 bytes), as Finder counts. One copy can never exceed the total budget.
4. Ranges: items 10–5,000, days 1–365, total 10–5,000 MB, per copy 1–500 MB (values outside are pulled to the edge).
5. The pasteboard content present when the feature starts is not recorded (only new copies).
6. Priority when a copy has several formats: files > rich text (RTF) > text > image. A copy with text and RTF is stored
   as RTF (with the plain text); the same text copied as plain and as RTF are separate entries. Whitespace-only text is
   not recorded. HTML-only copies are not recorded.
7. Images are stored as PNG; the PNG path takes the bytes as they come, TIFF is converted. Conversion runs on the main
   thread (bounded by the per-copy limit on the TIFF).
8. Source app: the pasteboard's `org.nspasteboard.source` marker when present, else the frontmost app at poll time
   (up to 0.5 s late).
9. Choosing an entry moves it to the top (new date), also from the menu bar tab. The tab's click is copy-only and closes
   the panel; only the popup pastes.
10. Dedupe is by SHA-256 of kind + content, not by preview.
11. Menu bar tab: pinned entries in their own "Pinned" group above "Recent"; while searching a single "Results" list;
    Clear is a two-step button (3 s confirm) and keeps pinned entries; the list is capped at 450 pt.
12. Popup: 380 pt wide, up to 8 rows (44 pt) visible, ↑/↓ clamp at the ends, hover selects only after the pointer moves,
    closes on a click outside, on losing key, on Esc, on a second press of the shortcut. No number shortcuts, no
    pin/delete in the popup.
13. "Copied" toast shows 1.4 s (2.8 s with a hint line), dismissed early through the toast's own dismiss closure.
14. The folder is 0700, files 0600, excluded from Time Machine backups.
15. Orphaned blob files (crash between blob and index write) are swept at load, but never when the index was corrupt
    (those blobs may be what the user wants to recover).
16. Entries whose blob file has vanished are dropped at load; an entry that fails to load at paste time is removed with a
    toast.
17. `stop()` keeps the history in memory (small) so the Settings page keeps showing right numbers after switching the
    feature off; only decoded thumbnails are released.
18. Ignored apps default to none; password managers are handled by the marker types.
19. The popup is a fresh window per open and is destroyed on close; nothing of it exists in between.

## Shell changes
- `Sources/OrbitApp/main.swift`: **one added line**, `ClipboardDebug.runIfRequested(CommandLine.arguments)` after
  `SuiteSnapshot.runIfRequested`, for the `--check-clipboard` / `--snapshot-clipboard-*` modes. Other feature agents may
  add similar lines; expect a trivial merge there. Everything else stays in the owned folders.
- Uses, unchanged: `PanelHostingView` (from `MenuBarPanel.swift`) and `HUDPlacement` (from `HUDPanel.swift`),
  `KeyComboRecorder`, `PermissionBadge`, `SettingsSection`, `PanelTile` & co., `GlassBackground`.
- Not used (not on my base): the shell's later `SnapshotFixtures`. I made an equivalent local helper in
  `ClipboardFixtures` (absolute-path `.plist` in the temp folder, removed at exit). The controller can switch it over.

## Needs verification on Kevo's Mac (I could not run the live app)
1. **Paste with Accessibility**: turn Clipboard on, grant Accessibility (Settings → Clipboard → Grant Access), copy text in
   Safari, press ⇧⌘V, ↓/↑, Return: the text should land in Safari's field and Safari must stay frontmost. Repeat with
   "Paste straight into the app" off, and with Accessibility revoked (expect a "Copied" toast with the hint).
2. **Typing in the non-activating popup**: the search field should accept typing and ↑ ↓ Return Esc the moment the popup
   appears (the same unverified risk as the shell's menu bar panel: key focus in a non-activating panel).
3. **Focus**: after choosing or Esc the app you came from must still be the active app, with its caret where it was.
4. **Hot key**: ⇧⌘V is taken over from other apps (Paste and Match Style) while Clipboard is on; turning the feature off
   must give it back.
5. **Password managers**: copy a password from 1Password / Passwords / Keychain: it must not appear in the tab.
6. **Big copies**: a > 20 MB image must be refused (the whole pasteboard data is read before its size is known).
7. Image copy from Preview (TIFF), a screenshot to the clipboard (PNG), files copied in Finder (paste them back in a
   Finder window), RTF from TextEdit pasted into a rich-text field.
8. Popup placement near screen edges, on the other displays, and over a full-screen app.
9. Restart Orbit: the history comes back.

## Known gaps
- No live run of the popup, the key handling, the global hot key, ⌘V posting or the pasteboard watcher on the real
  pasteboard (only the reader/writer through named pasteboards and the views through snapshots).
- A huge pasteboard item (a 200 MB image) is read into memory once before it can be refused; macOS has no size query.
- The source app is a guess (frontmost at poll time) for apps that don't write the source marker.
- Text beyond the first 200 characters is stored but not searchable (per the brief).
- HTML-only copies, file promises (Mail attachments) and multiple pasteboard items are not recorded.
- No number-key quick pick, pin or delete from the popup.
- `Clear` in the menu bar tab clears the whole history even while a search is typed.
- The popup's "paste" hint is decided when it opens; if Accessibility is granted while it is open the line stays "copy".

## Housekeeping
- My first snapshot runs used a fixture helper that wrote an empty `orbit-fixture-<uuid>.plist` into the user temp folder
  (`/var/folders/.../T/`, **not** `~/Library/Preferences`). I confirmed all 11 files were created during my runs and held
  only my `clipboard.ignoredBundleIDs` key (two inspected with `plutil`, the rest matched by size and timestamp), and removed
  exactly those. The helper now deletes its plist at exit (verified: none left after a run).
- Nothing was ever written to `~/Library/Preferences` or `~/Library/Application Support/Orbit` (no `*.plist` of mine
  there); the real pasteboard was never read or written, no key events were posted, and no Orbit window was shown.

---

# Fix round 1

Five findings from the task review, all fixed on `suite/clipboard` (not pushed). Commits (each ends with the
`Co-Authored-By: Claude Opus 5.5` trailer):

| Commit | Finding | Subject |
|---|---|---|
| 357b96a | I1 | fix(clipboard): an unreadable index never costs blobs |
| fdee680 | M4 | fix(clipboard): pinned entries are exempt from the count and size budgets |
| e5f68fd | I2 | fix(clipboard): press ⌘V only when the previous app is confirmed frontmost |
| 6f07f40 | I3 (core) | feat(clipboard): decode, convert and hash raw copies off the main thread (core) |
| cdbc5fa | I3 + M1 (app) | fix(clipboard): heavy work off the main thread; discard a read the pasteboard changed under |

Tests: 32 → **46** Clipboard tests (14 new). Full suite after the round: `swift test` → `Test run with 607 tests in 32 suites
passed` (561 existing + 46). `--check-clipboard` → 23 PASS, exit 0 (was 18; five new cases).

## I1: corrupt-index recovery could delete every blob (357b96a)
Cause: the model treated `corruptBackup == nil` as "index was fine" and swept with `keeping: []`; and after a successful
rename the next launch saw a healthy index and swept the old blobs.
- `ClipboardStore.LoadResult.indexWasUnreadable`: set whenever an index file existed but could not be used, whether or not
  keeping a copy worked. `load(now:move:copy:)` tries the rename, then falls back to copying the file (the file operations
  are injectable for tests).
- `ClipboardStore.sweepOrphans(after:keeping:)`: does nothing when `indexWasUnreadable` or when entries were dropped on load.
  The model uses it instead of calling `removeOrphans` itself.
- Blobs are kept for backups too: `removeOrphans` protects every blob named by any `index.corrupt-*.json` (read leniently,
  including the blob name of entries that were themselves unreadable), and when any backup cannot be parsed at all (a
  truncated file, say) it deletes nothing, because no blob can then be proven unneeded. Consequence: after a real
  corruption, orphan sweeping stays off until the user removes the `index.corrupt-*` file(s); orphans are rare (a crash
  between writing a blob and the index) and small.
- If the unreadable index could be neither renamed nor copied, the model sets `persistenceBlocked`: it records and saves
  nothing this session, so the unreadable file is never overwritten and every blob stays as it is (logged).
- Tests (`ClipboardTests.ClipboardStoreTests`): `unreadableIndexNeverSweepsBlobs`, `failedMoveStillCountsAsUnreadable`
  (failing move falls back to a copy; failing move AND copy: no backup, flag set, nothing swept),
  `readOnlyFolderLosesNothing` (real `chmod 500` folder: unreadable index, blobs intact), `sweepNeedsAHealthyIndex`,
  `backupsKeepTheirBlobs` (next launch, healthy index: the blob only a backup names survives, a true orphan goes),
  `aBrokenBackupBlocksSweepingAltogether` (truncated backup + fresh index: nothing deleted).
  RED before the implementation: `error: value of type 'ClipboardStore' has no member 'sweepOrphans'` ×14,
  `... 'LoadResult' has no member 'indexWasUnreadable'` ×6, `extra argument 'move' in call` ×2. GREEN after: `Test run with
  38 tests in 6 suites passed` (one test expectation was corrected on the way: a truncated backup cannot name the blob
  of the entry that was cut off, which is why a broken backup now blocks sweeping altogether).

## M4: pinned entries counted toward the budgets (fdee680)
`enforce(limits:now:)` now measures the count and byte budgets over the UNPINNED entries only (age still applies only to
unpinned too). Pinned entries are exempt from every limit, as the spec intends, so a few big pins can no longer make every
new copy be written and evicted at once. Settings footnote: "Pinned entries are never removed automatically and don't
count toward these limits."
- Test `ClipboardHistoryTests.pinnedEntriesDoNotCountTowardBudgets`: three 600-byte pins against budgets of 2 entries /
  500 bytes: a fresh copy survives (`evicted.isEmpty`, 4 entries); unpinned entries are still held to their own budgets
  (450 + 100 bytes over 500: the oldest unpinned goes; three unpinned against 2: the oldest goes); pins untouched.
  RED: 4 issues (`none → [fresh]` should be empty, `history.count → 3` expected 4, ...). GREEN: `39 tests in 6 suites passed`.
  (`pinnedNeverEvicted` still passes unchanged.)

## I2: ⌘V was posted whether or not the previous app was frontmost (e5f68fd)
- `PasteInjector.bringToFront(_:)` now returns `Bool`: false for no app, a terminated app, or an app still not frontmost
  after the 0.8 s wait (macOS may refuse `activate` from an inactive app); true only when it really is frontmost.
- `ClipboardFeature.paste`: with no previous app (popup opened over Orbit itself) → "Copied" hint, no ⌘V. Otherwise ⌘V is
  posted only when `bringToFront` is true AND, after the 60 ms settle, `PasteInjector.isFrontmost(app)` is still true;
  otherwise the toast says "Press ⌘V to paste in <app>." (entry already on the pasteboard). `hide(restoreFocus:)` ignores the
  result (it only restores focus).
- No unit test (it depends on the live frontmost app); covered by the compile and by the verification list below.

## I3: heavy work on the main thread (6f07f40 core, cdbc5fa app)
- New `OrbitCore.RawPasteboardCopy` (Sendable; raw bytes only) with `makeCapture(maxItemBytes:)`: text decode + whitespace
  check, RTF plain-text parse, image decode + TIFF→PNG with ImageIO (`CGImageDestination`), and hashing
  (`ClipboardCapture.hashed()` / cached `contentHash`). The size limit is applied to what is STORED: the text, the RTF, or
  the PNG, not the (much larger, uncompressed) TIFF. `ClipboardLimits.maxRawImageBytes` (10 × the stored limit) only keeps
  absurd TIFFs from being converted at all.
- `PasteboardReader` (main thread, in the poll) now only fetches bytes and compares sizes: text through `data(forType:)`
  before any `String` is built (fallback to `string(forType:)` for pasteboards offering only another text encoding), RTF,
  PNG and TIFF bytes, file paths. It returns `.copy(RawPasteboardCopy)`.
- `ClipboardModel.ingest(_:)`: a serial chain of tasks (copy order is kept): `makeCapture` in `Task.detached`, then on the
  main actor the duplicate check, the blob write in `Task.detached`, then the insert, `enforceLimits` and the (small)
  index save. Duplicates still write no blob. `cancelIngest()` (called by `stop()`) drops queued copies; a blob written for
  a cancelled copy is deleted again.
- Tests (`ClipboardTests.RawPasteboardCopyTests`, 7): `textIsDecodedPreviewedAndHashed`,
  `oversizeAndWhitespaceAreSkippedBeforeAnyDecoding`, `richTextTakesItsPreviewFromThePlainText`,
  `tiffIsConvertedAndTheLimitAppliesToTheStoredPNG` (a 300 × 300 flat TIFF over a 100 KB limit is accepted because its PNG
  is tiny; the same size of noise is refused; accepted with a higher limit), `pngPassesThroughUnchangedAndGarbageIsRefused`,
  `filesKeepTheirPaths`, `rawImageReadLimitIsTenTimesTheStoredLimit`.
  RED: `cannot find type 'RawPasteboardCopy' in scope` ×16, `no member 'maxRawImageBytes'` ×4. GREEN: `Test run with 46
  tests in 7 suites passed`.
- `--check-clipboard` additions: `(setup) the TIFF is over the per-copy limit`, `a TIFF whose PNG fits is captured although
  the TIFF is over the limit` (500 × 500 flat TIFF vs a 200 KB limit), `a TIFF far beyond the limit is not even converted`.

## M1: marker check vs data read (TOCTOU) (cdbc5fa)
`PasteboardReader.read` takes the pasteboard's `changeCount` before it reads the types and compares it after it has read
the content; if it moved, the whole read is discarded (`.skipped("the pasteboard changed while it was being read")`). The
watcher has already recorded the earlier count, so the next poll sees a different count and reads again, now seeing the new
content's markers. A test hook (`afterTypes`) lets `--check-clipboard` change the pasteboard exactly between the two reads:
- `a pasteboard that changes mid-read is discarded` PASS, `... and the secret is refused on the re-read` PASS (the new
  content carries `org.nspasteboard.ConcealedType`).

## Commands and output
```
swift test --filter ClipboardTests          -> Test run with 46 tests in 7 suites passed
.build/debug/Orbit --check-clipboard        -> 23 PASS lines, "all clipboard checks passed", exit 0
swift test                                  -> Test run with 607 tests in 32 suites passed after 86.357 seconds
swift build -c release --arch arm64 --arch x86_64   -> Build complete! (exit 0), no warnings
```
(The full run this time was green including `ProcessTests`; the machine load was about 25 instead of 67.)

## [builder's call] additions
20. A backup that cannot be parsed blocks orphan sweeping for good (until the user removes the `index.corrupt-*` file);
    the alternative (a raw-text scan for blob names) cannot see names that a truncation cut off.
21. When the unreadable index could not even be copied aside, the session runs without saving (nothing is overwritten).
22. `maxRawImageBytes` = 10 × the stored limit (so a 200 MB TIFF is not converted when the per-copy limit is 20 MB).
23. Pinned entries are exempt from the age, count and size limits alike.
24. The "no previous app" and "frontmost not confirmed" cases fall back to copy-only with a toast naming the app.

## Still unverified live
The same list as above, plus: (a) with Accessibility granted, choosing an entry while another app took the front during the
popup (expect the "Press ⌘V to paste in <app>" toast and no keystroke); (b) a large TIFF copy (for example a big image from
Preview) must not make the menu bar or the cursor hitch.
