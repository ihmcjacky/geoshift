# Claude Code Project Configuration

## Commit Messages

When committing code, **do not include "Co-Authored-By" or any Anthropic-related attribution lines** in commit messages. Keep commit messages clean and project-focused.

## PowerShell Scripts (.ps1)

When creating or editing `.ps1` files intended to run on Windows:

1. **Always save with UTF-8 BOM.** Windows PowerShell 5.1 defaults to system codepage (CP1252); without a BOM it misreads any UTF-8 multi-byte character and produces cascading parse errors. The BOM (`\xEF\xBB\xBF`, shown as `﻿` at line 1) tells PowerShell to read the file as UTF-8.

2. **Use only plain ASCII characters throughout the entire file** — including comments, string literals, here-strings, and error messages. Non-ASCII characters such as em-dashes (`—`), en-dashes (`–`), curly quotes (`""`), and box-drawing characters (`─`, `──`) must be replaced with ASCII equivalents (`-`, `--`, `"`, `-`).

3. **When fixing character issues, grep the whole file**, not just the visually obvious spots. Run a check like `grep -Pn '[^\x00-\x7F]' file.ps1` to find every non-ASCII character before declaring the fix complete.
