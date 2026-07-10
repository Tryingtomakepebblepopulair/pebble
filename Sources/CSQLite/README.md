# CSQLite — vendored SQLite

- **Version:** 3.53.3 (amalgamation, `sqlite-amalgamation-3530300.zip`)
- **Source:** https://sqlite.org/2026/sqlite-amalgamation-3530300.zip
- **License:** public domain (https://sqlite.org/copyright.html)

Pebble ships its own SQLite so saves behave identically on macOS and
Windows (PORTING module 04). Update by replacing `sqlite3.c` and
`include/sqlite3.h` with a newer amalgamation and bumping this file.
