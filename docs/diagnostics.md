# The diagnostics log

When there is nothing to go on: the git probe, the probe cache, the project config read and the state file swallow
every failure, so a missing branch segment, a project config that never seems to apply, or a cache
that never seems to hit leaves nothing behind to look at. Set `CLAUDE_STATUSLINE_DEBUG` to `1` and
each swallowed failure, each cache hit and miss, each refused config and each state read and write
appends a line to `claude-statusline-diag.log` in your temp folder:

```text
2026-09-03T09:14:02.118Z 24880 git cache: miss (no entry yet)
2026-09-03T09:14:02.402Z 24880 git probe: git exited 128
2026-09-03T09:14:02.409Z 24880 config read: D:\repo\.claude\statusline.json was not read: it is 91204 bytes, over the 65536 byte cap
2026-09-03T09:14:02.415Z 24880 state: written (C:\Users\jim\AppData\Local\Temp\claude-statusline-state\abc.json)
```

A `statusline.json` that is not applied says which of the refusals it hit — it could not be opened,
the handle is not an ordinary file, it is a link or a reparse point (the project's file only), it is
over the byte cap, the deadline was spent, the file is empty, or it would not parse — so "why is my
config being ignored?" has an answer in the log rather than needing the script edited. Both files
report this way; the path in the line says which one it was.

The printed line is the same either way, and a log that cannot be written is as silent as the failure
it records. Writing a record is itself bounded: your temp folder is a filesystem like any other and
can be a share that stalls, so each record gets a quarter of a second and is dropped if it cannot be
written in that. A missing line is better than a status line that waits. Anything in a reason that a
terminal would act on rather than show — an escape, a format character — is written as `<U+001B>`
notation, because a repository's own config file can put text into a parser's error message, and a log
you open to read should not be able to clear your screen. The log rolls over into
`claude-statusline-diag.log.1` once it would pass 4 MB, so
leaving the variable set costs two files of that size at most, plus a small `.lock` file kept beside
the log to serialise a rollover against another render's — left behind by design rather than deleted
on release, since deleting it would race a process already waiting to open it. Treat the 4 MB as
approximate: the log is best-effort and never waits on anything, so two renders that overlap can leave
the file a little over the cap, or lose one of their lines to each other. Rolling over means renaming,
and a rename is the one thing here that cannot be put behind the deadline, so it is only attempted
when the folder has just answered two size questions quickly. If it has not — a share gone slow — the
record is dropped and the log sits at its cap until a render finds the folder responsive again, which
it does on its own. Unset the variable when you are done (`0`,
`false`, `no` and `off` also count as off) and delete all three files.
