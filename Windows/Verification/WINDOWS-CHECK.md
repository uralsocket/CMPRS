# First Windows check / Первая проверка Windows

This checklist remains unexecuted. Run on a normal, non-administrator Windows x64 account.

1. Open CMPRS-2.0.1-Windows-x64-Setup.exe → Install. Confirm CMPRS appears in Start and Installed apps. Test once with WebView2 absent if possible; the bootstrapper needs internet.
2. Select a short video → right-click → CMPRS — Compress video (Windows 11: Show more options / Shift+F10). Verify the eye blinks, moves and glances toward the advancing progress bar; there is no custom tagline/header.
3. Verify a smaller CMPRS-name.mov is saved beside the original. Compare source/output resolution, FPS and duration. Include one 4K file and a file above 60 FPS. Watch the output, especially its end and audio sync.
4. Select 3+ files and confirm a single window/queue. While running, send another file through Explorer. Include Cyrillic filenames, spaces, '&', an apostrophe and a filename ending in .mov.
5. Cancel midway. Confirm unfinished output is removed and completed copies remain. Reopen the same input and run again; an existing CMPRS- copy must be preserved and a numbered copy created.
6. Check Russian and English Windows, display scaling 100% / 150% / 200%, another monitor, resizing, and a queue of 20 files. The button must remain visible and the queue scroll.
7. Try HDR and 10-bit SDR. HDR must be skipped unchanged. SDR must request 8-bit conversion consent, once per approved batch; decline must preserve the original and create no copy.
8. Close the app. Re-run setup for an update; then uninstall through Installed apps. Check Explorer/Start/Send to entries disappear, videos remain, and reinstall works.

If anything fails, report the Windows version, what step failed, and the visible queue message. CMPRS intentionally does not generate logs.
