# GPU Picker

GPU Picker is a lightweight Windows utility for managing per-app GPU preferences using Windows power-saving and high-performance settings. Discover running apps, view GPU memory snapshots, and save preferences through a simple desktop interface, with optional daily sync.

Double-click **Open GPU Picker.vbs**. Uses built-in Windows PowerShell and Windows Forms; no installation or downloads.

This folder is the repository root. Local state in `data/` is ignored by Git and created on first launch. For development or smoke tests, put any custom `-DataDirectory` under `work/`, which is also ignored. Keep personal inventories and registry backups out of commits.

- Startup reads a fresh GPU snapshot and discovers running user apps. It does not apply preferences automatically.
- Existing Windows assignments are imported, including packaged-app IDs (Codex, Terminal, WhatsApp). The **Windows setting** column shows the assignment read at the last sync; **Use GPU** is the saved rule. Existing saved rules are retained if they differ from Windows. Sync/apply enforces those managed rules.
- Pick **Power saving**, **High performance**, or **Windows decides**, then **Save & apply**.
- **Unassigned** leaves the app untouched, including any existing Windows preference.
- **Sync** saves the choices in the grid, refreshes the snapshot and app list, and applies saved rules.
- **Add .exe** includes an application that is not currently running or whose process path could not be read.
- **Edit rule** lets you replace part of the executable's immediate parent folder with `*` (for example `MyApp\version-*\app.exe`). The installation root and executable name stay fixed. Select an app row, edit its rule, then **Preview matches** and **Save rule**. The rule must still match the reference executable, and all current matches are shown before saving. Packaged-app IDs cannot be edited.
- Restart an affected app yourself after changing its preference. GPU Picker never terminates apps.
- Double-click **Sync quietly.vbs** to run once without a window. Unknown apps are saved for review but never assigned automatically.
- Opening a second instance focuses the existing window when possible. Headless sync skips while the UI or another sync holds the store open.

Windows determines which GPU corresponds to Power saving and High performance. Check this mapping in Windows Settings > System > Display > Graphics before applying. These are Windows preferences; applications that explicitly select an adapter can override them. CUDA device selection remains the application's responsibility.

NVIDIA total VRAM comes from nvidia-smi. The per-app column uses Windows dedicated GPU memory counters **across all adapters**, not NVIDIA-only VRAM. Shared allocations can appear in multiple processes. Do not sum the column; `-` means unavailable, not zero. Some protected processes have unreadable executable paths and Windows system-directory processes are excluded. Performance counters may be unavailable on localized Windows installations.

## Updates and storage

Saved choices from earlier versions labeled AMD integrated or NVIDIA are automatically converted to Power saving or High performance when loaded.

`data/apps.json` contains the current app list and choices, not usage history. `apps.json.bak` is the previous saved list. Original registry values are retained in `data/original-preferences.json` before the first change to each path. An exclusive file handle prevents two instances from modifying storage together.

Discord, Discord Canary and Discord PTB version folders are resolved automatically inside their respective installation folders. Other applications start with their exact executable path. Use **Edit rule** for version-folder updates; future matching versions receive the saved preference during sync. Rules cannot overlap another existing app row, and wildcard expansion skips linked version folders. Saving a rule does not immediately apply GPU preferences; **Save & apply**, **Sync**, or scheduled sync applies it. Old Windows entries are left in place rather than deleting settings belonging to older installations.

## Optional daily sync

Run the following in Windows PowerShell from this folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\Enable daily sync.ps1'
```

This creates **GPU Picker daily sync** in Windows Task Scheduler, at noon for the current signed-in user. No background service is installed. Keep this folder in place after enabling the task. To remove it:

```powershell
Unregister-ScheduledTask -TaskName 'GPU Picker daily sync' -Confirm:$false
```

For an ordinary preference reset, choose **Windows decides**, Save & apply, then restart the app. This removes the explicit GPU selection while preserving unrelated graphics flags. Headless errors return a nonzero exit status for Task Scheduler.

## Verification

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\Test.ps1'
```

The UI and discovery can be smoke-tested with `-SmokeTest -DataDirectory <temporary-folder>`; this exits after loading the window and does not apply GPU preferences.
