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
on release, since deleting it would race a process already waiting to open it. The log never waits on
anything, so a render that finds that lock held by another one skips the rollover; when the log is
already full, it drops its record rather than appending past the cap, and says how many it dropped and
why in the next record it does get down (`[2 records dropped at the cap: another render holds the
rollover lock: 2]`). That note reaches you only when the same process writes again, which for a render
that draws one line and exits means usually not. The useful cross-process sign is a log near its cap
that has stopped growing while a live process holds its `.lock`; an older `.log.1` can still be there
from a previous rollover. Nothing is written anywhere else to tell you so, on purpose: another file to
write would be another filesystem call on the path that is dropping records rather than waiting for one.
A cap-drop note can name any of these reasons: `the record budget was spent inside the rollover`, `the rollover lock did not open inside the record budget`, `another render holds the rollover lock`, `the size read inside the rollover did not answer`, `the size of the log could not be read inside the rollover`, `the rollover could not complete`, `the size of the log could not be read before the rollover`, `the record budget was spent before the rollover was tried`, or `the rollover left the log full`. Rolling over means renaming, and a rename is the one thing here that cannot be put behind the deadline,
so it is only attempted when the folder has just answered two size questions quickly. If it has not — a
share gone slow — the record is dropped and counted the same way, and the log waits for a render that
finds the folder responsive again. What is left of 4 MB being approximate is small: the append itself
is not locked. `FileInfo.AppendText` opens with `FileShare.Read`, so overlapping renders can lose a
line to each other when one append open fails; the other can still leave the file a little over the cap
because both measured room before either wrote. Unset the
variable when you are done (`0`,
`false`, `no` and `off` also count as off) and delete all three files.

## Pinning the clock

`CLAUDE_STATUSLINE_NOW` replaces the wall clock the script reads once per render, so the cache
countdown, the rate-limit countdown, the pace arrow and the `time` segment all come out the same on
every run. It takes an ISO-8601 instant that **carries an offset** — `2026-01-15T14:05:00+00:00`, or
`Z`, or any offset within `±14:00`, which is as far as any real zone goes and as far as .NET will
parse — and that offset is the zone `time` prints its `HH:mm` in, so the same value renders the same
line on any machine in any zone. Anything else, an epoch count or an instant with no offset included,
is refused and the machine's own clock is used; with `CLAUDE_STATUSLINE_DEBUG` on, a refusal says so in
the log. It exists for `docs/render-screenshot.ps1` and the tests, which is why the two README
screenshots regenerate to the same text; leaving it set in a profile would freeze your status line's
clock at whatever instant it names.

It reaches the four figures on the line that move with the clock — the cache countdown, the rate-limit
countdown, the pace arrow and `time` — and nothing else. The git cache's freshness check and the state
directory's housekeeping sweep stay on the real clock on purpose: both compare against file times, and
the sweep deletes what it finds old.
