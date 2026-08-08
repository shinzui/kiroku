# Bundle Update Log

## 2026-08-08

* **Addition**: IR-1 requests a public global-head read and bounded `$all` / category paging so
  offline projection replays can prove completion through a captured frontier while concurrent
  appends continue. The request originates from Keiro IR-20 and is explicitly non-blocking.
