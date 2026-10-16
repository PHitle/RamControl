# RAM Control

A portable Windows process memory manager with an English / Russian interface, built with Windows PowerShell, WPF, and C# Win32 interop.

[Русская документация](README.ru.md)

## Run

1. Download and extract the source ZIP, or clone this repository.
2. Open `Start.cmd` on Windows 10/11.
3. Click a process, enter **Min RAM** and **Max RAM**, then click **Apply**.

No SDK, build step, external packages, or internet connection is required. Windows PowerShell 5.1 and .NET Framework compile `RamNative.cs` in memory at startup. This is a source distribution, not a compiled EXE.

Use the **Language** selector to switch between English and Russian without restarting. The choice is saved in `settings.json` next to the script. The directory must be writable to save it. Initially, Russian is selected for a Russian Windows UI; otherwise English is selected. A saved choice takes precedence. You can override the startup language:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\RamControl.ps1 -Language en
```

`Start.cmd` uses a process-scoped execution policy option and does not change your system execution policy. Organizational policies can still prevent scripts from running.

## Features and memory semantics

- Search by name or PID; refresh every two seconds.
- Apps with a main window and background processes are shown separately. This does not indicate CPU activity.
- **Private RAM**: private working set, resident pages private to the selected process.
- **Total WS**: full working set, including shareable pages. Both counters are read from the same snapshot when available.
- **Min RAM**: a soft working set minimum, not guaranteed reservation or forced allocation.
- **Max RAM**: a hard maximum for **Total WS**, not a committed-memory or virtual-memory cap. A low maximum can increase paging and slow down an application.
- Restore the original limits manually or automatically when RAM Control closes normally.

All memory input and displayed values use **MiB** (1,048,576 bytes). An unavailable private RAM value is shown as `—`, never replaced with zero or a different metric. Modern Windows uses `GetProcessMemoryInfo` with `PROCESS_MEMORY_COUNTERS_EX2`; older Windows falls back to `QueryWorkingSet`.

Compare the **same PID** in Task Manager's **Details** tab using **Memory (private working set)**. The Processes tab can aggregate multiple PIDs under an application, and its active private working set may differ for suspended processes. RAM Control does not aggregate applications or apply limits to their children.

Settings apply to the current process instance only. Limits are not persisted across application restarts. If RAM Control is forcibly terminated, limits can remain until the target application restarts. Protected processes may deny access. Raising the minimum or managing an elevated application may require administrator privileges. Elevation is not requested automatically. Native Windows error details follow the operating system language.

## Source layout

| File | Purpose |
| --- | --- |
| `RamControl.ps1` | Process list, validation, localization, settings, and event handlers |
| `RamNative.cs` | Windows process memory APIs and privilege handling |
| `MainWindow.xaml` | WPF window, controls, and styles |
| `locales/en.psd1`, `locales/ru.psd1` | Translation dictionaries |
| `Start.cmd` | Portable launcher |

Preserve **UTF-8 with BOM** for `.ps1` and `.psd1` files so Windows PowerShell 5.1 reads Cyrillic text correctly. Add matching keys to both translation dictionaries when adding interface text. Do not commit `settings.json`.

## Checks

Run in Windows PowerShell:

```powershell
.\RamControl.ps1 -SelfTest -Language en
.\RamControl.ps1 -UiTest -Language en
.\RamControl.ps1 -UiTest -Language ru
```

`SelfTest` checks translation keys, validation, memory readings, and applies/restores a limit on a disposable child PowerShell process. `UiTest` loads the WPF interface without showing the window and checks memory columns, selection, search, both languages, and preservation of entered limits and selected PID when switching languages. Tests do not change limits on existing user applications or save language preferences. A Windows GitHub Actions workflow runs these checks on pushes and pull requests.

## License

MIT. See [LICENSE](LICENSE).
