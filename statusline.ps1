#Requires -Version 7.0
# Claude Code status line (PowerShell 7) with Nerd Font glyphs and ANSI colour.
# Wants a Nerd Font in the terminal (install.ps1 can set up JetBrainsMono Nerd Font); where the font
# cannot be changed, "style": "ascii" draws every glyph the script chooses in printable ASCII instead,
# and keeps the colours. Payload text - a branch, a folder, a name - is drawn as it arrived in any style.
# Reads the JSON Claude Code pipes on stdin and prints one or two lines, e.g.
#   󰚩 Fable 5.1  󰍛 37% ████░░░░░░   $0.43   my-project   main
# Layout, separator style, segment toggles and order, colour bands and glyph overrides come from
# statusline.json next to this script, with the project's own .claude\statusline.json merged over it.
# Glyphs are emitted from code points so the file's own encoding never matters.
[CmdletBinding()]
param(
    # Path to the config file. Defaults to statusline.json beside this script; given, it replaces that
    # file and the project's own file is not read at all. Claude Code never passes it.
    [string] $Config
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# PowerShell strips ANSI colour when stdout is redirected unless told otherwise; the host always redirects it.
$PSStyle.OutputRendering = 'Ansi'

function G([int] $cp) { [char]::ConvertFromUtf32($cp) }
$e = [char]27
function C([string] $code, [string] $text) { "$e[${code}m$text$e[0m" }

# The payload, read as UTF-8 whatever the console is set to. Claude Code sends UTF-8; [Console]::In
# decodes with [Console]::InputEncoding, which comes from the console's INPUT code page - 437 on an
# ordinary Windows console, and the machine's OEM code page in a console the host makes fresh for the
# render, whatever the terminal itself is set to. So a branch, a folder or a name that was not English
# arrived here as mojibake before any segment had seen it - two characters of Japanese in, six of
# Latin-1 and box drawing out - in every style, on every render.
#
# A reader rather than an assignment to [Console]::InputEncoding, which would have fixed the decode
# just as well, and the reason is the byte order mark and not the code page. .NET builds [Console]::In
# with detectEncodingFromByteOrderMarks OFF, so a mark on the front of the payload survives into the
# string as U+FEFF and ConvertFrom-Json then refuses the whole thing. The reader below has that flag
# on, and the flag is the ONLY thing stripping the mark here: UTF8Encoding($false) has an empty
# preamble, so StreamReader's other check - the one that matches the encoding's own preamble - never
# fires. It also means a payload some other producer wrote as UTF-16 is read rather than arriving as a
# line of NULs. The smaller, second reason, stated accurately: assigning [Console]::InputEncoding
# writes the console's input code page when stdin is NOT redirected, and leaves it written after this
# process is gone; a reader of our own asks the console for nothing.
#
# Not redirected is the one case the reader gets WRONG, which is why it is not taken. A console hands
# its bytes over at its own input code page, so decoding them as UTF-8 would turn a pasted accent into
# a replacement character where [Console]::In got it right. Claude Code always redirects, and so does
# every invocation in the README and in test.ps1; typing at the script by hand is the case below.
# Everything else is swallowed and answered with the empty string, which is what an empty stdin already
# gives and what every caller downstream already handles: a status line that throws where the line
# should be is worse than one that prints its fallback.
function Read-StdinText() {
    if (-not [Console]::IsInputRedirected) { return [Console]::In.ReadToEnd() }
    $reader = $null
    try {
        $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false), $true)
        return $reader.ReadToEnd()
    } catch { return '' } finally { if ($null -ne $reader) { $reader.Dispose() } }
}

# ---- Diagnostics log ----
# The git probe, the probe cache and the state file swallow every failure on purpose: a status line
# that throws, or that prints an error where the branch should be, is worse than one that is a little
# stale. The cost is that "git still runs on every render" and "the state file never appears" cannot be
# looked into without editing the installed script. CLAUDE_STATUSLINE_DEBUG buys that back without
# giving the silence up: set to anything other than 0, false, no or off, each swallowed catch, each
# cache branch, each config refusal and each state read and write appends one line - UTC time, process
# id, reason - to claude-statusline-diag.log in the temp folder. Unset, which is the normal case, no
# call site does anything at all: see $script:diagOn below.
# Writing the log is itself silent, for the same reason the caller's catch is: a temp folder that is
# not there or cannot be written, or another render holding the file, costs the line and nothing else.
# The reason is folded onto one line, because an exception message can carry newlines and one call has
# to stay one line. Nothing here reaches the pipeline, so a call can sit in front of a return without
# changing what the caller returns.
# The log is rolled over rather than left to grow, and one record is bounded so that a reason of any
# length cannot set the size of the file on its own. The 4 MB cap holds even when the rollover cannot:
# a record with no room left and no rotation to land after is dropped rather than appended past it, and
# counted into the next record that does land. Invoke-StatusDiagRollover has the reasoning.

# Moves a log with no room left for the next record over claude-statusline-diag.log.1, so a variable
# left set in a profile costs two files of the cap's size at most rather than the temp volume.
# Two renders can be printing at once and would both see the same full file, so the move is taken
# under an exclusive lock on Path.lock, opened with FileShare.None, and the size is read again with
# the lock held: the second render then finds the small file the first one left and does nothing,
# rather than moving that over the archive the first one just made. The wait is zero. A render that
# finds the lock file already open elsewhere skips the rollover rather than waiting for it, so nothing
# here ever waits on another process - which is the point of a log that must not delay a render.
# What the caller then does with that skip is the other half of the trade, and it was the wrong half
# until #93: it appended anyway, on the reasoning that the file was about to shrink under it. It is
# not, when the holder is a render that has stalled, or one in another session or another user's
# account - and every render on the machine then appended past the cap for as long as that lasted,
# the log growing without bound in exactly the case the cap exists for. So a skip drops the record
# instead. Its answer is returned to the caller, which captures it: $true proves room, while every
# other answer is a reason to count a cap drop. Losing a record to a holder is the same trade every
# other call in this file makes with a filesystem that will not answer.
# The decision is a returned value, not a script variable. A variable reset on entry is fail-open:
# a future early return can default to "no skip", which the caller reads as room, and silently bring
# back the cap-growth bug. A return has the opposite default - a path that forgets to say anything
# returns
# $null, which is not $true, which the caller counts as a drop with the reason unknown. Wrong reason,
# right action. $true is returned on exactly three grounds, all of them meaning the log is not over its
# cap by the time this hands back: the rename happened, the size read under the lock found another
# render had already rolled it, or the file is not there at all. Everything else is a non-empty string
# saying which bound was hit, and the caller prints it.
# The append itself is still not locked, which leaves the cap approximate: FileInfo.AppendText opens
# with FileShare.Read, so two renders appending at the same instant do not both write - the second one's
# open throws and that
# record is dropped. Overlapping renders lose a line to each other, then, rather than each adding one
# past the cap, and the file can still finish a little over it because each measured room before the
# other wrote. What it can no longer do is go on growing for as long as somebody holds a lock.
# Anything that throws is Write-StatusDiag's to swallow. Nothing here reaches the pipeline by accident:
# every value this function produces is one it returns on purpose, and the caller captures it.
# $TimeoutMs is what is left of the record's clock, and now covers opening the lock as well as the
# size read: both are filesystem calls, dispatched to the pool and bounded like every other one here.
# The rename is the one call that stays unbounded; the caller decides whether the budget can afford
# it before calling at all, and the note at that call site says what that leaves.
# A lock file rather than a named mutex (#49): a bare mutex name on .NET/Unix is scoped to the POSIX
# session, so two renders in different terminals - the likely shape of this race - never contended at
# all, and a Global\ name (tried and reverted here) traded that for two worse holes, both reproduced:
# a second Windows user's handle to it fails the default DACL before the constructor returns, and on
# Unix every Global\ name shares one directory whose creator can leave every other user locked out of
# it - either way the whole record silently dropped through the catch below. A lock on Path.lock is
# scoped by the filesystem path instead: users with separate temp folders never contend at all, and on
# a shared /tmp another user's lock is the UnauthorizedAccessException case below, not a collision this
# function mistakes for its own kind of contention. The kernel releases the handle on process exit the
# same as any other, so a killed render leaves no stale lock to answer for. See #49 for the measurements.
#
# A lock open that outlasts the budget is abandoned here but is not thereby gone: the task keeps
# running against the real filesystem underneath, and when it finishes - a moment later, or whenever a
# starved thread pool gets to it - the handle it hands back would sit open, unclosed, for the rest of
# the process if nothing ever asked it what happened. That handle is this process's own, so every
# rollover after it would see a sharing violation - the IOException case below - against itself rather
# than against another process, which is indistinguishable from real contention from in here and would
# make the cap gone rather than approximate for the rest of the process's life. A mutex could not do
# this: a WaitOne(0) that returns false holds nothing.
# The fix is not a continuation on the abandoned task: ContinueWith runs its callback on whatever thread
# the task happens to finish on, which is generally a pool thread, and a PowerShell script block is not
# callable there - verified empirically, it fails with "no Runspace available to run scripts in this
# thread" every time, silently as far as the task that hosts it is concerned, since an unobserved
# faulted continuation raises nothing anyone here would see. So the check is made eagerly instead, by
# Clear-StatusDiagPendingHandle, on whichever later record happens to come next: it looks at whatever
# abandoned tasks earlier calls left running and disposes the result of any that have finished by then.
# It runs at the top of EVERY record and not only of the ones that reach a rollover. A leaked handle in
# this process holds Path.lock until something disposes it; while it does, every render on the machine
# now loses every record it tries to write once the log is full, where before they merely overshot the
# cap. Waiting for the next record that happens to find the log full is too long to wait for that, and
# the sweep costs a null check and a Count on every record that has nothing to sweep, which is all of
# them but the pathological ones. A render that writes no further record leaves the handle for the
# process exit, the same answer this file gives everywhere else a wait would cost more than it is worth.
# That dispose is a filesystem close - the one call in this sweep that touches the disk at all - so it
# goes to the pool and is bounded by what is left of this call's own budget, floored the same 20 ms as
# the live lock's own close below: a stalled share is exactly what this guard exists for, and closing a
# finished handle from it on the render's own thread would reintroduce the wait the pool dispatch exists
# to avoid. The list itself is bounded too, not just each entry in it: a share stalled long enough would
# otherwise take one abandoned task per render forever. That bound is a gate on the way IN rather than a
# trim on the way out, which is the review finding this replaces: dropping the oldest task still running
# to make room for a newer one hands its handle to nobody, which is exactly the leak this guard exists to
# stop, and nine consecutive overrunning opens on a stalled share is all it takes to get there. So a call
# whose handle would have to be kept is not started at all once eight are outstanding -
# Request-StatusDiagPendingCall below refuses it, and the record is dropped and counted like any other cap
# drop. Nothing is ever evicted, so every handle this process made is owned by this list until it is
# closed. The list drains itself: the sweep above removes each entry as it finishes, so the first record
# after the share recovers takes the whole backlog and the one after that is ordinary again.
# The append open a record abandons below is the same defect in a second place, and it gets this sweep
# rather than a second copy of it: what a timed-out append open leaves behind is a handle on the log
# itself, and FileInfo.AppendText shares that for reading only, so it refuses the next record's own open
# and every ordinary read of the file besides - which is #94. Both cases are an abandoned task whose
# result is an IDisposable only this process can close, so the list holds handles of either kind and
# diagUnlockMethod - IDisposable's own Dispose, reflected once - closes a StreamWriter exactly as it
# closes a lock's FileStream. It is also why this runs at the very top of a record rather than beside
# the rollover: a leaked writer is precisely what would refuse the open the record is about to make.
# Only an OPEN that overruns is owned here. A close that overruns reads alike and is not the same thing:
# it is a Dispose already running, which finishes on its own a moment later and takes the handle with it,
# so there is nothing left for anyone to own. An open that overruns is a handle not made yet with nobody
# left to close it, because the call that asked for it has gone. A render writes one line and exits, so
# there it would be invisible; in a process that writes many - a test run, or anything that dot-sources
# this - one overrun record cost every record after it, which is #94.
# The eager half of the abandoned-handle guard the comment above describes, split out of the rollover so
# that every record runs it and not only the ones that find the log full. Nothing here reaches the
# pipeline and nothing is returned: a caller cannot act on the result of a sweep, only benefit from it.
# The list being empty is the normal case and costs a null test and a Count.
function Clear-StatusDiagPendingHandle([int] $TimeoutMs) {
    if ($null -eq $script:diagPendingHandles -or $script:diagPendingHandles.Count -eq 0) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = $script:diagPendingHandles.Count - 1; $i -ge 0; $i--) {
        $pending = $script:diagPendingHandles[$i]
        if ($pending.IsCompleted) {
            if ($pending.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                $closeLeft = [Math]::Max($TimeoutMs - [int] $sw.ElapsedMilliseconds, 20)
                $closePending = [System.Threading.Tasks.Task]::Run([System.Delegate]::CreateDelegate([Action], $pending.Result, $script:diagUnlockMethod))
                [void] [System.Threading.Tasks.Task]::WaitAny(@($closePending), $closeLeft)
            }
            $script:diagPendingHandles.RemoveAt($i)
        }
    }
}

# The two halves of owning an abandoned handle, one place each rather than the same three lines copied at
# both call sites. Request is the gate, and a gate rather than a check a caller could forget to make: it
# answers $null when the list is already full, and nothing has been started when it does. The bound
# cannot be applied after the fact - a task already running cannot be given up again without leaking the
# handle it is about to make - which is why the cap lives here and not in the sweep. Add is only ever
# reached through a Request that said yes, which is why it does not have to create the list itself.
function Request-StatusDiagPendingCall($Call) {
    if ($null -eq $script:diagPendingHandles) { $script:diagPendingHandles = [System.Collections.Generic.List[object]]::new() }
    if ($script:diagPendingHandles.Count -ge 8) { return $null }
    return [System.Threading.Tasks.Task]::Run($Call)
}
function Add-StatusDiagPendingHandle($Task) { $script:diagPendingHandles.Add($Task) }

# Whether a filesystem call failed because the thing it names is not there, as against failing for any
# other reason. Its own helper because getting it wrong is silent and expensive: FileNotFoundException
# and DirectoryNotFoundException both DERIVE from IOException, so a test for IOException first swallows
# them, and a test that treats every fault as "not there" reads a share that flapped as an empty log -
# which is how a record came to be appended past the cap without anything noticing. FileInfo.Length
# raises FileNotFoundException for a missing directory as well as a missing file, verified on this
# platform; DirectoryNotFoundException is named anyway because other calls in this file raise it and
# because the .NET contract allows either.
function Test-PathAbsent($Ex) {
    return ($Ex -is [System.IO.FileNotFoundException] -or $Ex -is [System.IO.DirectoryNotFoundException])
}

# Count every record that the cap rejected. The reasons are kept separately because one later record
# must not claim that all of several losses had the last loss's cause. An unknown answer is still a
# drop: the caller fails closed whenever the rollover did not prove there is room.
function Add-StatusDiagDrop([string] $Why) {
    if ([string]::IsNullOrEmpty($Why)) { $Why = 'the rollover left the log full' }
    if ($null -eq $script:diagDropReasons) { $script:diagDropReasons = @{} }
    $script:diagDropReasons[$Why] = 1 + [int] $script:diagDropReasons[$Why]
}

function Invoke-StatusDiagRollover([string] $Path, [long] $Need, [long] $Cap, [int] $TimeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $call = Get-StatusDiagDelegate $Path
    # Both budget checks answer with the same words on purpose. The second one is a rounding boundary
    # and nothing else - reaching it means the wait below returned inside its own timeout while the
    # elapsed whole milliseconds had just caught up with it - so a reason distinguishing the two would
    # be a distinction no reader could act on and no test could reach.
    $left = $TimeoutMs - [int] $sw.ElapsedMilliseconds
    if ($left -le 0) { return 'the record budget was spent inside the rollover' }
    $open = Request-StatusDiagPendingCall $call.Lock
    # The same words as the append open's refusal below, deliberately: it is one rule with one count, and
    # two spellings of it in the log would read as two causes.
    if ($null -eq $open) { return 'too many abandoned handles from earlier records are still outstanding' }
    if ([System.Threading.Tasks.Task]::WaitAny(@($open), $left) -lt 0) {
        Add-StatusDiagPendingHandle $open
        return 'the rollover lock did not open inside the record budget'
    }
    if (-not $open.IsCompletedSuccessfully) {
        # Held elsewhere is IOException on every platform this was checked on - Windows, and .NET
        # Core 3.1 and .NET 8 on Linux - and nothing else here throws that from a plain OpenWrite:
        # no lock, no rollover, and no wait either, the zero-wait skip-on-contention trade #43 chose.
        # The caller drops the record on the strength of the answer below (#93). Anything else -
        # chiefly UnauthorizedAccessException, a lock file some other user left behind that this one
        # cannot open at all, permanently rather than for as long as a holder lives - is a structural
        # failure the same as a directory occupying .log.1, and is let through so the whole record is
        # dropped by the caller's catch rather than appended past the cap forever. The absent cases are
        # excluded from the contention test rather than left to fall inside it: they derive from
        # IOException, and a temp folder that has gone is not a holder anybody is going to let go of.
        if ($open.Exception.InnerException -is [System.IO.IOException] -and -not (Test-PathAbsent $open.Exception.InnerException)) {
            return 'another render holds the rollover lock'
        }
        throw $open.Exception.InnerException
    }
    $lock = $open.Result
    try {
        $left = $TimeoutMs - [int] $sw.ElapsedMilliseconds
        if ($left -le 0) { return 'the record budget was spent inside the rollover' }
        $size = [System.Threading.Tasks.Task]::Run($call.Length)
        if ([System.Threading.Tasks.Task]::WaitAny(@($size), $left) -lt 0) { return 'the size read inside the rollover did not answer' }
        if (-not $size.IsCompletedSuccessfully) {
            # No file is nothing to move, and nothing for the caller to be held back by either: the log
            # is not over its cap when this returns, whoever it was that emptied it. Any OTHER fault is
            # a size this function does not know - a share that flapped reads exactly like an empty log
            # from here - and answering $true to that is what let a record through past the cap.
            if (Test-PathAbsent $size.Exception.InnerException) { return $true }
            return 'the size of the log could not be read inside the rollover'
        }
        # Under the cap with the lock held: the render that was holding it has already rolled the file,
        # so there is room and nothing left to do.
        if ($size.Result + $Need -le $Cap) { return $true }
        [System.IO.File]::Move($Path, $Path + '.1', $true)
        return $true
    } finally {
        # A floor under the wait rather than skipping it once the budget is gone: "returned from here"
        # is meant to mean "the lock is free again" inside this same process, the same handle-scoped
        # correctness the continuation above exists for, and skipping the wait entirely would let this
        # call's own close race the very next one's open. The floor is small because it is not trying to
        # be a bound - nothing here is - only to give an ordinary close, which is fast, room to land
        # before this function hands back a "the lock is free" answer that might not be true yet.
        $left = [Math]::Max($TimeoutMs - [int] $sw.ElapsedMilliseconds, 20)
        $close = [System.Threading.Tasks.Task]::Run([System.Delegate]::CreateDelegate([Action], $lock, $script:diagUnlockMethod))
        [void] [System.Threading.Tasks.Task]::WaitAny(@($close), $left)
    }
}

# What one record may cost. The log is written from the render path, and the temp folder is a filesystem
# like any other: it can be redirected onto a network share, and a share can stall. A helper that wrote
# straight through would then hold a render open for as long as the share took, which is worse than
# anything the log is there to diagnose. So every filesystem call one record makes goes to the thread
# pool and is waited on for what is left of one clock, the same shape the project config read uses, and
# a record that cannot be written inside it is dropped. Losing a line is the right trade against holding
# the line up, and it is the trade #43 already made when it took a zero wait on the rollover lock and
# an approximate cap over guaranteed ones.
# What that trade costs is more than the one line: an open that overruns leaves a handle on the log with
# nobody left to close it. Clear-StatusDiagPendingHandle above owns that, and its note has the reasoning.
# RolloverMs is how much of that budget has to be left before the one call this function cannot bound -
# the rename a rollover does - is attempted at all. Half, so that reaching it means both size reads
# answered in well under half a record's clock. The note at the call site has the reasoning.
function Get-StatusDiagLimit { return @{ TimeoutMs = 250; RolloverMs = 125 } }

# The three filesystem calls a record's own thread may need, each closed over a FileInfo for the log's
# path (or, for Lock, the path plus the reflected OpenWrite this cache keeps beside it) so every one can
# go straight to the pool. Same rule as the bounded config read, and for the same reason: a script block
# converted to a delegate needs a runspace and a pool thread has none, so these are delegates over
# zero-argument members of plain .NET types. Length is what the rollover decision needs and throws when
# there is no file yet, which is read as a size of zero rather than as a failure. AppendText opens the
# file for append and hands back a StreamWriter that is UTF-8 without a byte order mark, which is what
# the log is; the writer buffers, so putting a line into it is memory and the bytes reach the disk on
# the close, which is the one call after the open that touches the filesystem and is bounded like it.
# Lock opens Path.lock exclusively for the rollover; File.OpenWrite is one argument closed the same way
# the other two are, which is why the rollover's lock goes through this factory rather than building its
# own - a test that replaces this factory replaces every filesystem call a record can make, the lock
# included, rather than leaving one real disk write no double can reach. diagUnlockMethod is cached
# beside diagLockMethod for the same reason: IDisposable.Dispose is the one member every lock result -
# a real FileStream or a test double's stand-in - answers to, so a single reflected MethodInfo, looked
# up once, closes either.
function Get-StatusDiagDelegate([string] $Path) {
    $info = [System.IO.FileInfo]::new($Path)
    if ($null -eq $script:diagLockMethod) {
        $script:diagLockMethod = [System.IO.File].GetMethod('OpenWrite', [type[]] @([string]))
        $script:diagUnlockMethod = [System.IDisposable].GetMethod('Dispose', [type[]] @())
    }
    return @{
        Length = [System.Delegate]::CreateDelegate([Func[long]], $info, [System.IO.FileInfo].GetProperty('Length').GetMethod)
        Append = [System.Delegate]::CreateDelegate([Func[System.IO.StreamWriter]], $info, [System.IO.FileInfo].GetMethod('AppendText'))
        Lock   = [System.Delegate]::CreateDelegate([Func[System.IDisposable]], ($Path + '.lock'), $script:diagLockMethod)
    }
}

function Write-StatusDiag([string] $Reason) {
    $flag = $env:CLAUDE_STATUSLINE_DEBUG
    if (-not $flag -or $flag.Trim() -in @('0', 'false', 'no', 'off')) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $writer = $null
    $budget = 0
    $landed = $false
    $written = $false
    try {
        $limit = Get-StatusDiagLimit
        $budget = $limit.TimeoutMs
        # A late lock open, or a late append open, can finish after its original record gave up, leaving
        # this process itself holding .lock or the log. Sweep both on every later record, including
        # under-cap ones, so a lock cannot make a long quiet stretch look like contention by every other
        # render, and so a leaked writer is gone before this record opens a writer of its own.
        Clear-StatusDiagPendingHandle $budget
        $base = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [System.IO.Path]::GetTempPath() }
        $path = [System.IO.Path]::Combine($base, 'claude-statusline-diag.log')
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $text = [regex]::Replace($Reason, '\s+', ' ').Trim()
        # A reason can carry text this script did not write. A JSON parser quotes the property names it
        # choked on, and in a project config those names come from the repository. A log is read in a
        # terminal, so an escape left in one runs there rather than being read: ESC [ 2 J clears the
        # display, taking with it the evidence the log was opened to look at. Every control, format and
        # surrogate code point is therefore written as visible notation, here rather than at any call
        # site, so that no caller now or later can be the one that forgets. Notation rather than
        # removal, because a log exists to show what was there: <U+001B> says an escape was in the text
        # where dropping it would say nothing was. That is the opposite of what Format-PayloadText does
        # to payload text on its way to the line, and deliberately so - the line has to be safe to look
        # at, the log has to be honest about what it found. Folding runs first, so a tab or a newline is
        # still a space rather than notation; \s does not match ESC, which is the point.
        $text = [regex]::Replace($text, '[\p{Cc}\p{Cf}\p{Cs}]', { param($m) '<U+{0:X4}>' -f [int] $m.Value[0] })
        # A record is one line a person reads, and an exception message has no length limit, so a reason
        # past 1000 characters is cut and marked. The cut comes after the escaping, so a reason made
        # long by notation is cut too and nothing can outgrow the cap by being escaped.
        if ($text.Length -gt 1000) { $text = $text.Substring(0, 1000) + ' [cut]' }
        # All cap drops are carried by the first record that really lands. A map, not one overwritten
        # reason, preserves the accounting when several different rollover answers happen in one host.
        if ($null -ne $script:diagDropReasons -and $script:diagDropReasons.Count -gt 0) {
            $dropCount = [int] (($script:diagDropReasons.Values | Measure-Object -Sum).Sum)
            $dropWhy = @($script:diagDropReasons.Keys | Sort-Object | ForEach-Object { "$($_): $($script:diagDropReasons[$_])" }) -join '; '
            $text += " [$dropCount record$(if ($dropCount -ne 1) { 's' }) dropped at the cap: $dropWhy]"
        }
        $line = "$stamp $PID $text`n"
        $need = [System.Text.UTF8Encoding]::new($false).GetByteCount($line)
        $call = Get-StatusDiagDelegate $path
        $left = $budget - $sw.ElapsedMilliseconds
        if ($left -le 0) { return }
        $size = [System.Threading.Tasks.Task]::Run($call.Length)
        if ([System.Threading.Tasks.Task]::WaitAny(@($size), [int] $left) -lt 0) { return }
        if ($size.IsCompletedSuccessfully) {
            $have = $size.Result
        } elseif (Test-PathAbsent $size.Exception.InnerException) {
            $have = 0
        } else {
            Add-StatusDiagDrop 'the size of the log could not be read before the rollover'
            return
        }
        $left = $budget - $sw.ElapsedMilliseconds
        if ($have + $need -gt 4MB) {
            # Renaming is the one unbounded filesystem call. Do not start it late, but count this drop
            # exactly as every returned rollover failure is counted.
            if ($left -lt $limit.RolloverMs) {
                Add-StatusDiagDrop 'the record budget was spent before the rollover was tried'
                return
            }
            $room = try { Invoke-StatusDiagRollover $path $need 4MB ([int] $left) } catch { 'the rollover could not complete' }
            # $true is the sole proof that a move happened, another render left room, or the file went
            # away. Every other answer, including a structural failure, is a reason string (and an
            # accidental future $null is fail-closed).
            if ($room -ne $true) {
                Add-StatusDiagDrop $room
                return
            }
            $left = $budget - $sw.ElapsedMilliseconds
        }
        if ($left -le 0) { return }
        $open = Request-StatusDiagPendingCall $call.Append
        if ($null -eq $open) {
            Add-StatusDiagDrop 'too many abandoned handles from earlier records are still outstanding'
            return
        }
        # Nothing here is waiting on this task any longer, so it goes to the sweep rather than on the
        # floor: whatever it opens is a handle on the log with nobody left to close it.
        if ([System.Threading.Tasks.Task]::WaitAny(@($open), [int] $left) -lt 0) {
            Add-StatusDiagPendingHandle $open
            Add-StatusDiagDrop 'the append open did not answer inside the record budget'
            return
        }
        # A handle an earlier record abandoned can finish in the gap between the sweep at the top of this
        # one and the open just above, and AppendText then cannot have the file at all. That is a lost
        # record like any other, and it is counted rather than returned in silence: the reason is the only
        # thing that tells it apart from a record nobody asked for.
        if (-not $open.IsCompletedSuccessfully) {
            Add-StatusDiagDrop 'the log could not be opened for append'
            return
        }
        $writer = $open.Result
        # Into the writer's buffer, which is memory: a record is far shorter than the buffer, so nothing
        # reaches the disk until the close below.
        $writer.Write($line)
        $written = $true
    } catch { $null = $_ } finally {
        # Write has handed the line to the writer before the close starts. A pending close is not a
        # failure, so it consumes the carried accounting exactly once; only a close already known to have
        # failed leaves the note for a later record.
        if ($null -ne $writer) {
            try {
                $close = [System.Threading.Tasks.Task]::Run([System.Delegate]::CreateDelegate([Action], $writer, [System.IO.TextWriter].GetMethod('Dispose', [type[]] @())))
                $left = $budget - $sw.ElapsedMilliseconds
                if ($left -gt 0) { $null = [System.Threading.Tasks.Task]::WaitAny(@($close), [int] $left) }
                $landed = $written -and -not $close.IsFaulted
            } catch { $null = $_ }
        }
        if ($landed) {
            $script:diagDropReasons = $null
        }
    }
}
# Whether the log is on, decided once for the process, and the thing every call site asks before it
# builds a reason or calls anything.
#
# The gate inside Write-StatusDiag is cheap, but it is reached too late to be free: PowerShell builds
# the argument first, so "git cache: hit ($($info.Branch))" is interpolated on every render whatever
# the flag says, and the call itself costs about seventy microseconds before the helper gets to decide
# it has nothing to do. Measured on this machine, an unset flag cost about ninety-six microseconds a
# call site that way. Deferring only the string - a script block argument - saved about twenty of that,
# because the call, not the interpolation, is most of it. Testing a variable first costs nothing
# measurable at all, and there are around thirty call sites, several of them on the path of every
# render. So the call sites read `if ($script:diagOn) { Write-StatusDiag ... }` and an unset variable
# means no interpolation, no call and no work of any kind.
#
# Write-StatusDiag keeps its own gate rather than trusting the callers': the environment variable stays
# the one thing that decides, so the helper is still correct called on its own, and a call site that
# forgets the guard is a missed optimisation rather than a log that writes when it should not.
function Test-StatusDiagFlag {
    $flag = $env:CLAUDE_STATUSLINE_DEBUG
    return [bool] ($flag -and $flag.Trim() -notin @('0', 'false', 'no', 'off'))
}
$script:diagOn = Test-StatusDiagFlag

# ---- The clock, read once ----
# Four things on a rendered line move with the wall clock and with nothing else: the prompt cache
# countdown, the rate-limit countdown, where the pace arrow sits in the five-hour window, and the
# `time` segment's HH:mm. Each of them used to read its own clock at the moment it was built -
# Get-CacheSecondsLeft, TimeLeft and Get-PaceArrow through the default on their $Now parameter,
# Get-TimeSegment through a bare Get-Date - so one render measured its figures against several
# readings taken milliseconds apart, and docs/render-screenshot.ps1 could never regenerate a PNG to
# the same bytes twice: it built the payload's expiries against ITS clock and the child process a
# second or two later measured them against its own, which is enough to cross a minute boundary, and
# the wall clock in the two-line shot was simply whatever time the capture happened at. Reading once,
# here, and handing that one value to all four makes THE CLOCK-RELATIVE FIGURES ON THE LINE a function
# of the payload, the config and this value.
#
# That claim is about the line, and not about the process, and the difference matters to anyone
# reading this to work out what a pinned render does. The script still reads the real clock in five
# other places, none of which puts a figure on the line: the diagnostics record's own UTC stamp, the
# over-cap marker a git stamp falls back to, the git cache entry's TTL comparison, the state
# directory's housekeeping sweep, and the state record's updated_at. Two of those - the TTL and the
# sweep - MUST stay on the real clock and say so at their own call sites, because they compare against
# filesystem timestamps that no environment variable moves.
#
# CLAUDE_STATUSLINE_NOW replaces the reading, and is read exactly once, here, the way
# CLAUDE_STATUSLINE_DEBUG is. It is for the screenshot renderer and for the tests; nothing in normal
# use sets it, and with it unset this is the same clock the four call sites each read on their own
# before, so what production prints is unchanged byte for byte.
#
# THE VALUE MUST CARRY AN OFFSET, AND THAT IS THE ZONE RULE: an ISO-8601 instant ending in Z, or in
# +hh:mm / -hh:mm. `time` prints a wall clock, and a wall clock without a zone is not a time anyone
# can reproduce - the same instant is 14:05 on one machine and 09:05 on another, which is the whole
# thing this seam exists to stop. The offset in the string IS the zone the wall clock is printed in:
# 2026-01-15T14:05:00+00:00 prints 14:05 and 2026-01-15T16:05:00+02:00 prints 16:05, on any machine in
# any zone, and the two are the same instant so every countdown on the line is identical between them.
# A value with no offset, an epoch count, or anything else at all is refused and the machine's own
# clock is used - the same answer an unset variable gets. Refusing rather than repairing is the rule
# every payload number in this script already follows, and guessing a zone is the one repair that
# would quietly reintroduce the defect.
function Get-StatusNow([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    # The pattern is the validation and TryParse below is only the parse, and the order matters: given
    # a string with no offset, [DateTimeOffset]::TryParse does not refuse it, it SUPPLIES THE MACHINE'S
    # OWN OFFSET, which is the one answer this must never give. The pattern is what makes the offset
    # mandatory; everything TryParse is left to decide - a 31st of February, a 25th hour, a 61st
    # minute - is a real calendar question the pattern has no business answering.
    # \z and not $, which in .NET also matches in front of a newline at the end of the string: a value
    # carrying a second line would otherwise be validated on its first and parsed as a whole.
    if ($text -notmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})\z') { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref] $parsed)) { return $null }
    return $parsed
}

# The one reading. It is the ONLY place in this file that a figure on the line gets a clock from,
# and the three countdown helpers default their $Now to it, so a new call site that says nothing about
# time is on the seam rather than off it: opting in per call was how the four readings happened in the
# first place. This accessor deliberately does not repair a wrong value. Production assigns a
# DateTimeOffset immediately below; a caller or test that breaks that invariant must see the failure
# rather than silently take a separate new reading.
function Get-StatusClock() {
    return $script:renderNow
}
$script:renderNow = Get-StatusNow $env:CLAUDE_STATUSLINE_NOW
if ($null -eq $script:renderNow) {
    # A variable that was set and then refused earns a line, because the symptom - a screenshot that
    # still moves between runs - looks exactly like the seam not working at all. The value goes in
    # whole: Write-StatusDiag escapes what a terminal would act on, folds the newlines a record must
    # not carry, and cuts at 1000 characters with a [cut] marker. Cutting it here as well would hide
    # that marker behind a shorter, unmarked truncation, and a fixed character count can land between
    # the halves of a surrogate pair and put half a character in the log.
    if ($script:diagOn -and $env:CLAUDE_STATUSLINE_NOW) {
        Write-StatusDiag "clock: CLAUDE_STATUSLINE_NOW refused (wants an ISO-8601 instant carrying an offset), got '$($env:CLAUDE_STATUSLINE_NOW)'"
    }
    # The machine's clock, taken once. All later figures read this value through Get-StatusClock,
    # and [DateTimeOffset]::Now appears in exactly one place in the file.
    $script:renderNow = [DateTimeOffset]::Now
}

# The built-in code point of every glyph the segments use, keyed by the name the icons key of
# statusline.json takes: the $icon* constant minus its prefix, lower-cased. The constants themselves
# are assigned from Get-IconSet once the config is read, so an override is in place before any builder runs.
function Get-IconDefault {
    return @{
        model    = 0xF06A9   # nf-md-robot
        context  = 0xF035B   # nf-md-memory
        cache    = 0xF0238   # nf-md-fire  (prompt cache warmth)
        cost     = 0xF0114   # nf-md-cash
        # nf-md-timer_outline, the outline stopwatch. Issue #8 named that glyph and then wrote F13AB
        # beside it, which is nf-md-timer, the filled one; the name is what says how the glyph should
        # look, so this is F051B, the code point the Nerd Fonts glyph list gives that name.
        clock    = 0xF051B   # nf-md-timer_outline
        # nf-md-clock_outline, the outline wall clock, checked against the Nerd Fonts glyphnames.json
        # the cheat sheet is generated from and rendered out of JetBrainsMono NF by docs/render-icons.ps1
        # before the builder was written. It is a DIFFERENT glyph from `clock` above and deliberately so:
        # that one is a stopwatch, for how long this session has run, and this one is a wall clock, for
        # what time it is. Two segments, two numbers, two faces.
        time     = 0xF0150   # nf-md-clock_outline
        folder   = 0xF07C    # nf-fa-folder_open
        chevron  = 0x203A    # single right-pointing angle quotation mark (between owner/name and the leaf)
        branch   = 0xE0A0    # powerline branch
        worktree = 0xF04C1   # nf-md-source_fork (the session is in a git worktree)
        home     = 0xF015    # nf-fa-home  (on main/master)
        dirty    = 0xF040    # nf-fa-pencil (uncommitted changes)
        ahead    = 0x2191    # up arrow (commits ahead of upstream)
        behind   = 0x2193    # down arrow (commits behind upstream)
        conflict = 0xF071    # nf-fa-exclamation_triangle (merge conflicts)
        pr       = 0xF407    # nf-oct-git_pull_request
        lines    = 0xF121    # nf-fa-code  (lines added/removed)
        limits   = 0xF0E4    # nf-fa-tachometer (rate limits)
        fast     = 0xF0E7    # nf-fa-bolt  (fast mode)
        think    = 0xF09D1   # nf-md-brain (extended thinking)
        effort   = 0xF04C5   # nf-md-speedometer (effort level)
        vim      = 0xE62B    # nf-custom-vim
        agent    = 0xF007    # nf-fa-user (the custom agent driving the main thread)
        session  = 0xF02B    # nf-fa-tag  (the name the user gave the session)
    }
}

# The same names again for the ascii style, as plain characters rather than code points, because a
# stand-in is not always one character and an empty one is not a code point at all.
#
# WHAT ASCII MEANS HERE, and the rule every entry below follows. EVERY CHARACTER THIS SCRIPT CHOOSES is
# printable ASCII, U+0020 to U+007E: the stand-ins below, the marks in Get-MarkSet, the separator in
# Format-Line. That is a stronger promise than "no Nerd Font glyphs", and deliberately: ASCII is the only
# range that is both always drawable and always one cell wide, and the width half matters as much as the
# font half, because Get-VisibleWidth counts a meter block, an arrow or a middle dot as one column while
# a terminal in an East Asian locale may draw any of them as two.
#
# WHAT IT DOES NOT COVER, and must not: TEXT THAT CAME FROM THE PAYLOAD. A branch, a folder, a repo
# owner, a model name, an agent or session name reaches the line as the payload supplied it, in this
# style exactly as in the other two. The style exists for the glyphs the SCRIPT picked, which live in
# the private use area and need a font a terminal may not have; a name in Japanese needs a Japanese
# font, which most terminals do have, and it is the user's own data either way. Transliterating it would
# be lossy and silent, and it would make this style worse than no style for the very people most likely
# to be on a terminal they cannot configure - a branch drawn as boxes at least says "this font is
# missing", where one rewritten to `????` says nothing and cannot be read back. So: the script's own
# characters are ASCII here, the payload's are the payload's, and test.ps1 pins exactly that.
#
# So Get-MarkSet answers for the characters that are not icons, and this table answers for the icons:
#
#   1. An entry is EMPTY where what follows it already names the segment - the model's own name, a
#      figure that starts with a dollar sign, a +156 -23 diff, a 5h 24% window, an effort level, a vim
#      mode, an elapsed time. A stand-in there would be a label on something already labelled. An empty
#      entry leaves no space behind it, which is Format-Icon's job and not each builder's.
#   2. Otherwise a CONVENTIONAL ASCII MARK where one already exists for the thing: ~ for home, * for a
#      dirty tree (the git prompt's own mark), ^ and v for ahead and behind, ! for a conflict, / for a
#      step down a path, @ for a person, # for a tag.
#   3. Otherwise the SHORTEST LOWER-CASE ABBREVIATION that names it - ctx, dir, pr, wt, fast, think -
#      cut to a single initial where the segment's own text already carries the word: b for branch, and
#      c for cache, whose short form is a bare `warm` or `8m` and would otherwise reach a narrow line
#      with nothing on it saying what the figure is about.
#
# Three of the marks share a line with characters the branch segment writes itself - + for staged, ~ for
# modified, ? for untracked - so ahead and behind may not be any of those three. The home mark is a ~,
# which the modified count also uses; the two never read alike because a count is always a mark followed
# by a digit and the home mark is always followed by a space and a branch name.
# The chevron is a / rather than a > so it cannot be read as the separator between segments, which is
# also a >; both sides of it are path parts, so a slash says what the chevron said.
# A fresh table each call, like Get-IconDefault, so a caller that changes its copy cannot reach the next.
function Get-IconAscii {
    return @{
        model    = ''
        context  = 'ctx'
        cache    = 'c'
        cost     = ''
        clock    = ''
        # Clause 1, the same answer `clock` gets and for the same reason: 14:05 names itself. The two
        # can be on one line together and still not be read for each other - the stopwatch prints
        # letters and a pipe, 1h12m | api 38%, and this one is the only thing on the line with a colon
        # in it - so neither needs a label to tell them apart.
        time     = ''
        folder   = 'dir'
        chevron  = '/'
        branch   = 'b'
        worktree = 'wt'
        home     = '~'
        dirty    = '*'
        ahead    = '^'
        behind   = 'v'
        conflict = '!'
        pr       = 'pr'
        lines    = ''
        limits   = ''
        fast     = 'fast'
        think    = 'think'
        effort   = ''
        vim      = ''
        agent    = '@'
        session  = '#'
    }
}

# The characters a line is drawn from that are not icons: the meter's two cells, the minus in front of
# the removed count, the clock's separator, the two pace arrows, and the tail Get-ClippedText puts on a
# name it cut. They are not in the icons table because they are not icons - none of them stands for a
# segment, and none of them is a glyph a user would swap - so they are not config-overridable either.
# Taken as a parameter rather than read from a script variable so the builders' unit tests can ask for
# either style without the script's startup having run.
function Get-MarkSet([string] $Style) {
    if ($Style -eq 'ascii') {
        return @{ BarFull = '#'; BarEmpty = '.'; Minus = '-'; Middot = '|'; Steady = '='; Rising = '^'; Ellipsis = '.' }
    }
    return @{ BarFull = (G 0x2588); BarEmpty = (G 0x2591); Minus = (G 0x2212); Middot = (G 0xB7); Steady = (G 0x2192); Rising = (G 0x2191); Ellipsis = (G 0x2026) }
}

# An icon and the text it introduces, joined by the one space between them. THE SPACE LIVES HERE, in one
# function, rather than as a literal in twenty builders: the ascii table leaves seven entries empty, and
# an empty icon has to leave no space behind it or every one of those segments starts a cell to the
# right of where it should. Every site that puts an icon in front of text goes through this; the few
# that use an icon on its own - the mode badges, the worktree badge with no name, the pencil, the count
# prefixes - do not, and none of those icons is ever empty.
function Format-Icon([string] $Icon, [string] $Text) {
    if (-not $Icon) { return $Text }
    return "$Icon $Text"
}

# The Unicode categories an icon code point may not have. A config is not always the user's own - a
# repository's .claude\statusline.json reaches the icons table too - so a code point is admitted only
# when the terminal can draw it as one glyph standing by itself. Control and Format cover a bare escape,
# a right-to-left override, a directional isolate, a zero-width joiner and a byte order mark, any of
# which can reorder or hide the rest of the line without breaking the escape syntax; the two separators
# would break the line in half; the three marks attach to whatever came before them instead of standing
# alone; a surrogate half is not a character; and an unassigned code point has no glyph, so the terminal
# draws a placeholder of its own choosing. Private use is deliberately not on the list: every Nerd Font
# glyph the script ships lives there.
function Get-IconRefusedCategory {
    return @(
        [System.Globalization.UnicodeCategory]::Control
        [System.Globalization.UnicodeCategory]::Format
        [System.Globalization.UnicodeCategory]::Surrogate
        [System.Globalization.UnicodeCategory]::OtherNotAssigned
        [System.Globalization.UnicodeCategory]::SpaceSeparator
        [System.Globalization.UnicodeCategory]::LineSeparator
        [System.Globalization.UnicodeCategory]::ParagraphSeparator
        [System.Globalization.UnicodeCategory]::NonSpacingMark
        [System.Globalization.UnicodeCategory]::SpacingCombiningMark
        [System.Globalization.UnicodeCategory]::EnclosingMark
    )
}

# A code point from a config value: a string of hex digits, with U+ or 0x allowed in front, space around
# it and leading zeros, at most six digits once those are gone. What comes back is a code point that
# draws as a single glyph: inside Unicode, not a noncharacter (xFFFE, xFFFF and FDD0 to FDEF, which no
# process may interchange), none of the categories above, and one or two cells wide by the script's own
# width rule, so an override can never throw the fitting off. $null for anything else, so the caller
# keeps the built-in glyph.
function Read-CodePoint($Value) {
    if ($Value -isnot [string]) { return $null }
    $hex = $Value.Trim()
    if ($hex.StartsWith('U+', [StringComparison]::OrdinalIgnoreCase) -or $hex.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) { $hex = $hex.Substring(2) }
    $hex = $hex.TrimStart('0')
    if ($hex.Length -lt 1 -or $hex.Length -gt 6) { return $null }
    $cp = 0
    if (-not [int]::TryParse($hex, [System.Globalization.NumberStyles]::AllowHexSpecifier, [cultureinfo]::InvariantCulture, [ref] $cp)) { return $null }
    if (-not [System.Text.Rune]::IsValid($cp)) { return $null }
    if (($cp -band 0xFFFE) -eq 0xFFFE -or ($cp -ge 0xFDD0 -and $cp -le 0xFDEF)) { return $null }
    if ([System.Text.Rune]::GetUnicodeCategory([System.Text.Rune]::new($cp)) -in (Get-IconRefusedCategory)) { return $null }
    if ((Get-VisibleWidth ([char]::ConvertFromUtf32($cp))) -notin @(1, 2)) { return $null }
    return $cp
}

# One glyph per icon name: the built-in code point, or the config's override where its Icons table has
# one. A plain loop over the table, because this runs before the first line is printed.
#
# The ascii style takes the whole table instead and IGNORES THE OVERRIDES, which is the one place this
# function makes a decision rather than merging. An override is a code point, and a code point that is
# not ASCII is exactly what a terminal with no Nerd Font cannot draw, so honouring one here would let a
# config - a repository's own .claude\statusline.json included - take back the promise the style makes
# about the whole line. `style: ascii` therefore means ascii whatever else the file says, and a user who
# wants a glyph of their own is asking for a font. The refusal is logged rather than silent, because a
# setting that is read and then not used is worth being able to see.
function Get-IconSet($cfg) {
    if ($cfg.Style -eq 'ascii') {
        # The overrides are refused here rather than filtered: Read-CodePoint has already admitted any
        # code point that draws as one glyph, and "is it ASCII" is not a question the icons key was ever
        # asked. This is about the glyphs the script picks, and nothing here reaches payload text.
        if ($script:diagOn -and $cfg.Icons -is [hashtable] -and $cfg.Icons.Count -gt 0) {
            Write-StatusDiag "icons: $($cfg.Icons.Count) override(s) ignored under the ascii style"
        }
        return Get-IconAscii
    }
    $set = @{}
    foreach ($e in (Get-IconDefault).GetEnumerator()) {
        $cp = $e.Value
        if ($cfg.Icons -and $cfg.Icons.ContainsKey($e.Key)) { $cp = $cfg.Icons[$e.Key] }
        $set[$e.Key] = G $cp
    }
    return $set
}

$defaultEffort = 'high'   # effort badge is hidden at this level
# How many cells the agent and session badges may each spend on their name. Twenty is about as much as
# a name can take before the identity badges crowd out the branch and the folder on an ordinary window,
# and both badges share the one limit so a long pair cannot push the line further than a short pair.
$badgeNameCells = 20

# The git probe's settings when statusline.json has no git object: how long the branch segment waits
# for `git status` before giving up, how long a probe result is reused for, and whether it is reused at
# all. Read-StatusConfig starts from these. A fresh table each call, so a caller can change its copy.
function Get-DefaultGitConfig { return @{ TimeoutMs = 1500; CacheSeconds = 5; Cache = $true } }

# A whole-number config value clamped to $Min..$Max, or $Default when it is not a whole number at all:
# missing, a string, a boolean, a fraction. Get-FiniteNumber is the type test, so 3000.0 and 1e1 count
# as whole, and a value far outside Int32 clamps rather than throws.
function Get-ConfigInteger($v, [int] $Default, [int] $Min, [int] $Max) {
    $n = Get-FiniteNumber $v
    if ($null -eq $n -or $n -ne [math]::Floor($n)) { return $Default }
    return [int] [math]::Min([math]::Max($n, [double] $Min), [double] $Max)
}

# Visible cell width of a rendered line: escapes stripped, combining marks and the Unicode Format
# characters 0, CJK and emoji 2, else 1. Format is the whole category rather than the U+200B to U+200D
# range it used to be: a zero-width joiner, a bidi override, a directional isolate and a byte order
# mark all draw nothing, and counting one as a cell measures a line wider than it renders.
# A small wcwidth approximation; Nerd Font glyphs count as 1. The OSC strings go first, with either
# terminator (ESC \ or BEL), so a URL is never counted as text; then the SGR colour codes.
# One rule for every OSC command rather than one rule per command: an 8 hyperlink wrapper and the 9;4
# taskbar progress sequence are both "ESC ] anything terminator", which is exactly what a terminal that
# does not know the command swallows, so measuring them the same way is measuring what is drawn. The
# class excludes ESC as well as BEL, so the string stops at the ESC of an ESC \ terminator rather than
# running through it into the next escape.
function Get-VisibleWidth([string] $Text) {
    if (-not $Text) { return 0 }
    $plain = [regex]::Replace($Text, "`e\][^`a`e]*(?:`a|`e\\)", '')
    $plain = [regex]::Replace($plain, "`e\[[0-9;]*m", '')
    $width = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($plain)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $cp = try { [char]::ConvertToUtf32($el, 0) } catch { 0x3F }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($cp)
        if ($cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
            $cat -eq [System.Globalization.UnicodeCategory]::SpacingCombiningMark -or
            $cat -eq [System.Globalization.UnicodeCategory]::EnclosingMark -or
            $cat -eq [System.Globalization.UnicodeCategory]::Format -or $cp -eq 0xFE0F) { continue }
        # Two graphemes whose first code point says nothing about how wide they draw, so the ranges
        # below cannot see them: a flag is a pair of regional indicators, and a keycap is an ordinary
        # digit or # or * carrying U+20E3. Both are one text element and both take two columns in a
        # terminal, and left to fall through they would each be counted as one, which is the one
        # direction that matters - a name measured narrower than it draws passes a width cap it does
        # not fit and then overruns the line. Regional indicators are matched on the first code point,
        # so an unpaired one is two columns as well; a keycap is matched on the enclosing mark it ends
        # with, which a bare U+20E3 never reaches because the zero-width test above has already taken it.
        if (($cp -ge 0x1F1E6 -and $cp -le 0x1F1FF) -or $el.Contains([char] 0x20E3)) { $width += 2; continue }
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or
            ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
            ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or ($cp -ge 0x20000 -and $cp -le 0x3FFFD) -or
            ($cp -ge 0x1F300 -and $cp -le 0x1F64F) -or ($cp -ge 0x1F680 -and $cp -le 0x1F6FF) -or
            ($cp -ge 0x1F900 -and $cp -le 0x1FAFF) -or ($cp -ge 0x2600 -and $cp -le 0x27BF)) { $width += 2; continue }
        $width += 1
    }
    return $width
}

$ellipsis = G 0x2026   # what a clipped name ends in; the ascii style reassigns it once the config is read

# Plain text clipped to $Width cells, with a one-cell ellipsis when anything was cut. Measured by text
# element, so a surrogate pair or a combining sequence is never split down the middle. The result is
# never wider than $Width.
# Cells, not characters, and deliberately: Get-VisibleWidth is what Get-FittedLine measures a line with,
# so a version counting `.Length` would let a CJK or emoji name draw twice the room it was given and
# push the line past the width the fitting stage thinks it has. A wide character straddling the boundary
# is dropped whole rather than half-drawn, which can leave the result one cell short of the limit.
# subagent-statusline.ps1 carries the same function verbatim, for the agent panel's row identities, and
# test.ps1 compares the two copies as text; this one is the source.
function Get-ClippedText([string] $Text, [int] $Width) {
    if ($Width -le 0) { return '' }
    if ((Get-VisibleWidth $Text) -le $Width) { return $Text }
    if ($Width -eq 1) { return $ellipsis }
    $out = ''
    $used = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $w = Get-VisibleWidth $el
        if ($used + $w -gt $Width - 1) { break }
        $out += $el
        $used += $w
    }
    return $out + $ellipsis
}

# The segment table: one record per segment, in layout-one order. It is the single source for the config
# defaults, the shrink and drop order in Get-FittedLine, the build dispatch and the layout-two rows.
# Build names the builder function; the build loop calls it with the payload, the config and the session
# state, and a builder that wants fewer of those leaves the rest in $args, which is why the call shape is
# one line there rather than a signature per segment. It returns the segment record or $null. Default
# seeds Read-StatusConfig. ShrinkRank orders stage one of Get-FittedLine for the segments that can have a
# Short form; a record whose Short is $null is skipped there, so a rank costs nothing on a render where
# that segment has no detail to shed. DropRank orders stage two, and the model record has none because it
# is never dropped.
# Row is the layout-two line and RowRank the position on it, because a row is not in layout-one order.
# The table is built once per run: a render asks for it several times, and this is on the startup path.
function Get-SegmentRegistry {
    if (-not $script:segmentRegistry) {
        $script:segmentRegistry = @(
            @{ Name = 'model';   Build = 'Get-ModelSegment';   Default = $true;  ShrinkRank = $null; DropRank = $null; Row = 1; RowRank = 1 }
            @{ Name = 'context'; Build = 'Get-ContextSegment'; Default = $true;  ShrinkRank = 4;     DropRank = 11;    Row = 2; RowRank = 1 }
            @{ Name = 'cache';   Build = 'Get-CacheSegment';   Default = $true;  ShrinkRank = 3;     DropRank = 4;     Row = 2; RowRank = 2 }
            @{ Name = 'cost';    Build = 'Get-CostSegment';    Default = $true;  ShrinkRank = 1;     DropRank = 6;     Row = 2; RowRank = 4 }
            @{ Name = 'clock';   Build = 'Get-ClockSegment';   Default = $true;  ShrinkRank = 8;     DropRank = 3;     Row = 2; RowRank = 5 }
            @{ Name = 'lines';   Build = 'Get-LinesSegment';   Default = $true;  ShrinkRank = $null; DropRank = 2;     Row = 2; RowRank = 6 }
            @{ Name = 'limits';  Build = 'Get-LimitsSegment';  Default = $true;  ShrinkRank = 2;     DropRank = 7;     Row = 2; RowRank = 3 }
            @{ Name = 'badges';  Build = 'Get-BadgesSegment';  Default = $true;  ShrinkRank = 7;     DropRank = 5;     Row = 1; RowRank = 5 }
            @{ Name = 'pr';      Build = 'Get-PrSegment';      Default = $true;  ShrinkRank = $null; DropRank = 8;     Row = 1; RowRank = 4 }
            @{ Name = 'folder';  Build = 'Get-FolderSegment';  Default = $true;  ShrinkRank = 6;     DropRank = 9;     Row = 1; RowRank = 2 }
            @{ Name = 'branch';  Build = 'Get-BranchSegment';  Default = $true;  ShrinkRank = 5;     DropRank = 10;    Row = 1; RowRank = 3 }
            # The wall clock, and the only record here whose Default is false: it is a segment nobody had
            # before this release, its value moves without a payload, and turning it on for every existing
            # install would change every render. It has no ShrinkRank because there is nothing in `14:05`
            # to shed, and DropRank 1 because it is the one figure on the line that says nothing whatever
            # about the session - not what it costs, not how full it is, not how long it has run.
            @{ Name = 'time';    Build = 'Get-TimeSegment';    Default = $false; ShrinkRank = $null; DropRank = 1;     Row = 1; RowRank = 6 }
        )
    }
    return $script:segmentRegistry
}

# Segment names sorted by one of the registry's rank keys, skipping records where it is $null. A row
# number limits the list to that layout-two row. Ranks are dense, 1 to N within the list asked for, so
# the names are dropped into slots by rank and read back in order: a plain loop over a hashtable, because
# this runs before the first line is printed and a cold pipeline, generic list or [array]::Sort each cost
# several milliseconds the first time.
function Get-SegmentOrder([ValidateSet('ShrinkRank', 'DropRank', 'RowRank')] [string] $Rank, [int] $Row = 0) {
    $slots = @{}
    foreach ($rec in Get-SegmentRegistry) {
        if ($null -ne $rec[$Rank] -and ($Row -eq 0 -or $rec.Row -eq $Row)) { $slots[$rec[$Rank]] = $rec.Name }
    }
    return @(for ($i = 1; $i -le $slots.Count; $i++) { $slots[$i] })
}

# The segment names in a config array, lower-cased and known to the registry, each at its first place:
# a repeat, an entry that is not a string and a name no segment has are skipped. $Seen carries the names
# already taken and is updated, so the second row of layout two cannot list a segment the first row has.
# $null when the value is not an array at all, which the caller tells from an empty list. A plain loop
# and array rather than a pipeline, because this runs on the startup path for every render.
function Read-SegmentNameList($Value, [hashtable] $Known, [hashtable] $Seen) {
    if ($Value -isnot [array]) { return $null }
    $names = @()
    foreach ($v in $Value) {
        if ($v -isnot [string]) { continue }
        $n = $v.ToLowerInvariant()
        if (-not $Known.ContainsKey($n) -or $Seen.ContainsKey($n)) { continue }
        $Seen[$n] = $true
        $names += $n
    }
    return , $names
}

# The built-in defaults: the table every config file is merged over. A fresh table each call, the nested
# tables included, so a merge that changes one caller's copy cannot reach the next caller's.
function Get-DefaultStatusConfig {
    $cfg = @{ Layout = 'one'; Style = 'plain'; Palette = 'dark'; Tint = 'role'; Folder = 'repo'; State = $true; Links = $true; Taskbar = $false; Segments = @{}; Git = Get-DefaultGitConfig }
    foreach ($rec in Get-SegmentRegistry) { $cfg.Segments[$rec.Name] = $rec.Default }
    $cfg.Order = @((Get-SegmentRegistry).Name)
    # The segments pushed against the right edge of the first line. Empty by default, which is the whole
    # of the old behaviour: with nothing to push against, Get-FittedLine pads nothing.
    $cfg.Right = @()
    $cfg.Rows = @((Get-SegmentOrder 'RowRank' 1), (Get-SegmentOrder 'RowRank' 2))
    $cfg.Thresholds = @{ Warn = 60; Bad = 85 }
    $cfg.Alarm = @{ Context = 90; Limits = 90 }
    $cfg.Icons = @{}
    $cfg.Quiet = @{ cost = 0.0; context = 0.0; limits = 0.0 }
    return $cfg
}

# The one-value config keys: the JSON name, the config key it lands in, and how the value is read. Enum
# takes a string that Allowed lists, folded to lower case; Bool takes a boolean. A value of any other
# shape leaves the key at the value beneath it. A new one-value key is one row here and nothing else; a
# key carrying an object or a list of its own gets a block of its own in Merge-StatusConfigFile, beside
# preset, segments, order, rows, thresholds, alarm, quiet, icons and git. `preset` is one of those: it
# is a string, but it stands for several keys at once rather than landing in one.
function Get-StatusConfigKey {
    return @(
        @{ Json = 'layout';  Key = 'Layout';  Kind = 'Enum'; Allowed = @('one', 'two') }
        @{ Json = 'style';   Key = 'Style';   Kind = 'Enum'; Allowed = @('plain', 'powerline', 'ascii') }
        # A separate axis from style, not a fourth style: style is the shape of a line and palette is
        # the colour numbers it is drawn with, so all six pairings are configurations this script draws.
        # dark is the table the script has always used, which is what keeps an existing config's line
        # exactly as it was.
        @{ Json = 'palette'; Key = 'Palette'; Kind = 'Enum'; Allowed = @('dark', 'light') }
        @{ Json = 'tint';    Key = 'Tint';    Kind = 'Enum'; Allowed = @('role', 'segment') }
        @{ Json = 'folder';  Key = 'Folder';  Kind = 'Enum'; Allowed = @('repo', 'leaf') }
        @{ Json = 'state';   Key = 'State';   Kind = 'Bool'; Allowed = $null }
        @{ Json = 'links';   Key = 'Links';   Kind = 'Bool'; Allowed = $null }
        @{ Json = 'taskbar'; Key = 'Taskbar'; Kind = 'Bool'; Allowed = $null }
    )
}

# A named starting point: one word standing for a layout, a style and the whole set of segment toggles,
# so a config that wants a common shape is {"preset": "minimal"} rather than nine booleans. The three
# names are built into this table and nothing here opens a path, so a preset named by a project config
# reads no file and needs no budget; it can only pick one of the shapes below.
#   minimal - which model, how full, where am I. One plain line.
#   cost    - the spend line, for watching a budget or a rate limit.
#   full    - everything, split across two powerline rows.
# $Name is untyped and gated here rather than declared [string], because a config file spells the value
# however it likes and a [string] parameter would turn a number or an array into a name instead of
# refusing it. An unknown name returns $null, which leaves the config exactly as it was.
# Each preset states every segment in the registry rather than only the ones it turns on, so a segment
# added later has to be placed in all three by hand; the test that compares these tables to the registry
# is what makes that a failure rather than a silent appearance in `minimal`. A fresh table every call,
# the nested one included, so a caller that changes its copy cannot reach the next caller's.
function Get-ConfigPreset($Name) {
    if ($Name -isnot [string]) { return $null }
    switch ($Name.ToLowerInvariant()) {
        'minimal' {
            return @{ Layout = 'one'; Style = 'plain'; Segments = @{
                    model = $true; context = $true; cache = $false; cost = $false; clock = $false; lines = $false; limits = $false
                    badges = $false; pr = $false; folder = $true; branch = $true; time = $false
                }
            }
        }
        'cost' {
            # The clock is on here and not in `minimal`: this preset is the line of numbers, and the
            # elapsed time is the denominator under every rate on it. `minimal` answers which model,
            # how full and where am I, and how long the session has run is none of the three.
            # The wall clock is off here for the same reason it is off in `minimal`: a line of numbers
            # about the session has no use for a number that is not about the session. `full` is the
            # only preset that turns it on, because `full` means everything.
            return @{ Layout = 'one'; Style = 'plain'; Segments = @{
                    model = $true; context = $true; cache = $true; cost = $true; clock = $true; lines = $true; limits = $true
                    badges = $false; pr = $false; folder = $false; branch = $false; time = $false
                }
            }
        }
        'full' {
            return @{ Layout = 'two'; Style = 'powerline'; Segments = @{
                    model = $true; context = $true; cache = $true; cost = $true; clock = $true; lines = $true; limits = $true
                    badges = $true; pr = $true; folder = $true; branch = $true; time = $true
                }
            }
        }
    }
    return $null
}

# What a config file may cost to read - either of them, the user's own and the project's. A config a
# person wrote is a few hundred bytes, so 64 KiB is far past any real one and still reads in under a
# millisecond from a disk; the deadline is what a read that never finishes may cost, and the status line
# is redrawn on every event, so a quarter of a second is already longer than a render. Both are
# constants rather than config keys: they guard the file the config itself comes from.
# One pair of numbers for both files, because the thing being bounded is the same thing in both cases -
# a filesystem that does not answer - and it is not a trust judgement, so there is nothing about the
# user's file that would earn it a different budget. Measured before choosing that: the shipped 550-byte
# config takes about two milliseconds to read this way on a warm local disk, a fraction of a millisecond
# more than Get-Content took for the same file, and both are two orders of magnitude inside the deadline.
# So a second budget would have been two numbers to keep in step for no case either of them separates.
function Get-BoundedReadLimit { return @{ MaxBytes = 65536; TimeoutMs = 250 } }

# How many milliseconds a CONFIG read may take when the environment asks for more than the shipped
# budget, or 0 when it does not - which is every render outside a test harness, because the variable is
# read only when it is set, the shape CLAUDE_STATUSLINE_DEBUG already has here. Nothing else reads it:
# the git cache entry and the session state file keep the shipped budget, so what this can move is the
# two config files and nothing else.
#
# It exists for #99. test.ps1 renders the sample matrix in child processes that read a config the test
# itself wrote a moment earlier, under the same quarter-second budget a render gives a stranger's file;
# on a machine running four suites at once one of those reads misses it, that child draws the built-in
# defaults, and a random cell of the matrix fails for a reason the render is not responsible for. The
# suite sets this for its own children rather than the checks being loosened.
#
# It can only ever RAISE the budget, and that is the whole of its safety argument: the value is used
# only where it is larger than the shipped one, so no setting of it - not 0, not a negative number, not
# a word - can make a render's config read stricter than it is today. Anything that is not a whole
# number is ignored, and a value larger than a minute is capped at one, because past that the deadline
# has stopped being a deadline.
function Get-ConfigReadTimeout {
    $raw = $env:CLAUDE_STATUSLINE_CONFIG_TIMEOUT_MS
    if (-not $raw) { return 0 }
    $n = 0
    if (-not [int]::TryParse($raw.Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $n)) { return 0 }
    if ($n -le 0) { return 0 }
    return [math]::Min($n, 60000)
}

# The two calls the bounded read makes, each closed over the path so the open can go straight to the
# pool. Nothing here can be a script block: converted to a delegate one needs a runspace, and a thread
# pool thread has none. Delegate.CreateDelegate closes over the BCL File.OpenRead and File.GetAttributes
# methods, so it needs no runspace or emitted IL. File.OpenRead keeps FileShare.Read: a writer-held file
# is refused instead of read partway through that writer's truncate or flush, for either trust level.
# Ten fresh pwsh -NoProfile processes measured the shipped OpenRead delegate at min 11.864 ms and median
# 16.7369 ms. The rejected DynamicMethod measured min 31.427 ms and median 38.2225 ms by the same method,
# so emitted IL adds a real per-render cost. Both APIs are .NET Standard, so they hold on the 7.0 floor.
function Get-BoundedFileDelegate([string] $Path) {
    if ($null -eq $script:openMethod) {
        $script:openMethod = [System.IO.File].GetMethod('OpenRead', [type[]] @([string]))
        $script:attributesMethod = [System.IO.File].GetMethod('GetAttributes', [type[]] @([string]))
    }
    return @{
        Open       = [System.Delegate]::CreateDelegate([Func[System.IO.FileStream]], $Path, $script:openMethod)
        Attributes = [System.Delegate]::CreateDelegate([Func[System.IO.FileAttributes]], $Path, $script:attributesMethod)
    }
}

# The same trick for the two things done to an open stream that are filesystem calls in their own right.
# Length is not a field: on Windows it asks the handle for the file's size, which over SMB is a round
# trip to the server and can hang with the stream already open. Closing is a filesystem call too - a
# remote close goes back to the redirector - so it is queued rather than run where it could block the
# line. Both delegates are closed over Stream's own virtual members rather than FileStream's, so they
# dispatch through the same call whatever the stream turns out to be.
function Get-BoundedStreamDelegate($Stream) {
    return @{
        Length  = [System.Delegate]::CreateDelegate([Func[long]], $Stream, [System.IO.Stream].GetProperty('Length').GetMethod)
        Dispose = [System.Delegate]::CreateDelegate([Action], $Stream, [System.IO.Stream].GetMethod('Dispose', [type[]] @()))
    }
}

# ---- EVERY FILESYSTEM CALL A RENDER CAN MAKE, AND WHAT BOUNDS IT ----
# The audit #48 asked for, kept here beside the reader it is mostly about. A status line runs on every
# event, so any call here that does not answer is a line that does not draw. Each row is a decision, not
# a description: bounded (and how), deliberately unbounded (and why), or unreachable in practice.
#
#   BOUNDED, by the clock in Read-BoundedFileText (250 ms per file, 64 KiB cap). The clock is PER READ,
#   so two files that both hang cost two budgets, not one:
#     - the user's own statusline.json, beside this script or named by -Config. Bounded since #48,
#       because a home directory can sit on a network share too. Read as trusted: the link refusal below
#       is skipped, so a config symlinked out of a dotfiles repository still loads, which is how it
#       always worked.
#     - the project's .claude\statusline.json. Bounded since #19, and read as untrusted: it arrives with
#       the repository, so a handle that cannot seek, a reparse point and a directory are all refused.
#     - the git cache entry, in Get-CachedGitBranch, and the session state file, in Read-SessionState.
#       Both were one File.Exists and one ReadAllText on the render's thread, which is the same shape
#       the config read has and therefore cost one bounded read to fix rather than any new machinery.
#       Both files are written by this script, so both are read as trusted.
#     The two config files, and only those two, will take a LARGER budget from
#     CLAUDE_STATUSLINE_CONFIG_TIMEOUT_MS when it is set; see Get-ConfigReadTimeout for why and for
#     why it cannot make any of these reads stricter. Unset - which is every render this script was
#     written for - all four are the 250 ms above.
#   BOUNDED, by their own clock:
#     - the diagnostics log's size probe, rollover and append, in Write-StatusDiag: 250 ms for a whole
#       record, every call on the pool, with the rename attempted only above a reserve. Off entirely
#       unless CLAUDE_STATUSLINE_DEBUG is set, so the common render makes none of them.
#   BOUNDED, but not by a filesystem clock:
#     - git status itself, in Get-GitBranch: a child process under config git.timeoutMs, killed if it
#       overruns. The process is what waits on the filesystem, so git reaching into a dead share costs
#       that timeout and not a render. The timeout covers the CHILD and nothing this script does before
#       starting it - see the next group. Its timing mechanics belong to #63 and were left alone here.
#   DELIBERATELY UNBOUNDED, and stated by where each one really is rather than by where it is convenient
#   to say it is:
#     - the git probe's own precondition, in Get-GitBranch: one Test-Path on the directory the payload
#       named, on this thread, before the child process starts and so outside its timeout.
#     - the git cache's repository work, all of it before git runs and none of it under TEMP:
#       Get-GitRepoRoot walking up from the payload's directory looking for a .git, Get-GitStamp
#       stat-ing that git directory, enumerating the directories under refs and reading .git/commondir,
#       a file the repository itself writes.
#     - the writes. The state file and its sweep are after the line has been printed and nothing waits
#       on them but the process exit. THE CACHE ENTRY AND ITS SWEEP ARE NOT, and this row said they
#       were until a review checked it: Get-BranchSegment calls Get-CachedGitBranch while the segments
#       are being built, which is before anything is printed, so the entry write and the sweep that
#       follows it are in front of the line. Write-AtomicJson makes one move and never waits for an
#       open destination: a refusal drops this render's cache write, so the next render re-probes git.
#       That is a microsecond-scale failed move, not a render stall; a directory, read-only file or
#       another process's handle gets the same one attempt and no HResult-based retry.
#     - Get-SessionStateDir and Get-SessionStatePath, one Directory.Exists on the way to the state read.
#     Where those directories are is worth writing down, because the two are not the same rule.
#     Write-StatusDiag and Get-GitCacheDir go TEMP, then TMPDIR, then Path.GetTempPath();
#     Get-SessionStateDir goes TEMP, then $HOME/.claude/statusline-state. TEMP is normally set on
#     Windows and normally NOT set on Unix, so on Linux and macOS the log and the cache land in /tmp
#     while the state file lands under the home directory - which is the one of the three that can be a
#     network mount. Recorded rather than changed: moving the state file would strand every state file
#     already written, and the read of it is bounded now anyway.
#     - Get-Command git, a PATH scan on the render thread. One lookup, on directories the shell already
#       resolves for every command a user types.
#     So the honest version is that a project directory on a filesystem that hangs can hold a render up
#     in the walk or the stamps BEFORE the git timeout has anything to apply to. What holds THOSE back
#     from a budget is not that they cannot hang, it is what a budget would cost: the walk and the stamps
#     are many calls of several shapes where a config read is one open and one read, so a budget there
#     means a delegate per call and one clock threaded through four functions, and the probe's timing
#     mechanics are #63's. That reason was checked against each row rather than waved at all of them:
#     it did not hold for the cache entry or the state file, which are one existence test and one read
#     each, so those two are bounded above instead. Recorded rather than fixed, which is what #48 asked
#     for, and it is a decision about cost and not a claim that they are safe. What
#     stands today is a whole-render test in test.ps1 that points a payload at an unroutable UNC path
#     and bounds the render loosely, which catches a stack that hangs outright and not a slow one. The
#     stamp walk's cap of 256 ref directories and the sweep's cap of 200 deletions are about cost, not
#     about hanging, and neither is a deadline. The shape to copy, if any of this ever earns one, is
#     the reader below.
#   UNREACHABLE IN PRACTICE:
#     - install.ps1, docs/render-*.ps1 and tools/capture-stdin.ps1 make filesystem calls of their own
#       and none of them runs during a render.
#     - subagent-statusline.ps1 opens no file at all. It reads stdin, renders and exits.
#
# ABANDONMENT IS LITERAL, and anything that copies this pattern copies that too. When the budget is
# gone the reader does not cancel anything, because there is nothing here that can cancel a blocking
# filesystem call: it stops waiting and returns. A pool thread can stay stuck in the kernel until the
# process exits. A completed abandoned open is queued for a pool close, and a later bounded operation
# removes completed opens and closes without waiting; a task that never answers remains in the capped list
# until the process exits.

# Disposes completed abandoned opens on the pool and forgets completed close tasks. The sweep never
# waits: a stalled filesystem from one read must not spend a later healthy read's budget.
function Invoke-BoundedFilePendingSweep {
    if ($null -eq $script:boundedFilePending) { $script:boundedFilePending = [System.Collections.Generic.List[object]]::new() }
    if ($null -eq $script:boundedDisposeMethod) { $script:boundedDisposeMethod = [System.IDisposable].GetMethod('Dispose', [type[]] @()) }
    for ($i = $script:boundedFilePending.Count - 1; $i -ge 0; $i--) {
        $pending = $script:boundedFilePending[$i]
        $task = $pending.Task
        if ($pending.Kind -eq 'Open' -and $task.IsCompleted) {
            $script:boundedFilePending.RemoveAt($i)
            if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $null -ne $task.Result) {
                $close = [System.Threading.Tasks.Task]::Run([System.Delegate]::CreateDelegate([Action], $task.Result, $script:boundedDisposeMethod))
                $script:boundedFilePending.Add([pscustomobject]@{ Kind = 'Close'; Task = $close; Path = $pending.Path })
            }
        } elseif ($pending.Kind -eq 'Close' -and $task.IsCompleted) {
            $script:boundedFilePending.RemoveAt($i)
        }
    }
}

# The text of a config file, or $null when it is anything but a small, promptly readable one - and, for
# the project's file, an ordinary one. Test-Path and Get-Content are not enough here: they follow a link
# wherever it leads and read whatever comes back, for as long as it takes, so a repository could point
# the path at a device, a FIFO or a dead network share and hold up every render, or hand over a file
# large enough to matter, and a home directory can sit on that same dead share without any repository
# being involved. So one clock covers the whole thing, started before the first filesystem call of any
# kind, and every call runs on the thread pool and is waited on for what is left of it: the open, the
# file's length, the attribute probe, each read, and the close at the end. When the budget runs out the
# attempt is abandoned and the caller keeps the config it had, exactly like any other refusal.
# Abandonment is literal; the block above says what that means and why it is the right trade here.
# What the clock does not cover is what the caller does with the text afterwards, or a filesystem
# degraded enough to hang calls this function never makes.
#
# -Trusted is the user's own file, and it changes exactly one thing: the attribute probe is skipped.
# THE CLOCK AND THE CAP ARE NOT A TRUST JUDGEMENT - they are about a filesystem that does not answer,
# which is no respecter of whose file it is - so they apply either way. The probe is the trust
# judgement: it refuses a link, and a config symlinked out of a dotfiles repository is a normal thing to
# have and read fine before this function was pointed at it. Refusing one would be a config that
# vanished for no reason a user could see. The project's file gets the probe because a repository chose
# that path and this script did not. Skipping it also spends one filesystem call fewer on the file that
# is read on every single render, whether or not a project directory was named.
#
# Every refusal also names itself. A project config that is silently ignored is correct behaviour and an
# unanswerable support question at the same time, so each way out sets $why and the one call at the end
# writes it to the diagnostics log. The reasons are the cases this function already separates - it could
# not be opened, the handle is not an ordinary file, over the cap, a link or a reparse point, past the
# deadline, and which stage spent it - so the log says which of them a file hit rather than that it was
# ignored. Nothing is built when the log is off: the reasons are constants except on the paths that are
# already rare, and the message from a failed call is read only under the guard.
#
# The waits are WaitAny rather than Wait for one reason: Wait rethrows a task that failed, and the file
# not being there is the ordinary case for every project that keeps no config of its own, so that shape
# raised and caught an exception on every render - about 300 microseconds measured here, more than the
# pooled call itself costs. WaitAny returns -1 for the deadline and an index otherwise, and the task is
# then asked whether it succeeded, so the deadline and the failure are told apart instead of both
# arriving as one caught exception. The shared FileStream open still throws on the pool thread when a file
# is not there, but the fault is now read off the task rather than rethrown into a PowerShell catch, and the catch was where the cost was.
#
# $TimeoutMs is a caller's larger budget, or 0 for the shipped one. Only the config merge passes it, and
# only ever from Get-ConfigReadTimeout; it is taken when it is LARGER than the shipped deadline and
# ignored otherwise, so a caller cannot use it to tighten the clock on a file it is reading.
function Read-BoundedFileText([string] $Path, [switch] $Trusted, [int] $TimeoutMs = 0) {
    $limit = Get-BoundedReadLimit
    if ($TimeoutMs -gt $limit.TimeoutMs) { $limit = @{ MaxBytes = $limit.MaxBytes; TimeoutMs = $TimeoutMs } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    $why = $null
    $err = $null
    $closeErr = $null
    $closeStillPending = $false
    try {
         $null = Invoke-BoundedFilePendingSweep
        if (-not $Path) { $why = 'no path was given'; return $null }
        $call = Get-BoundedFileDelegate $Path
        # The open goes first and what it hands back is what gets judged, so there is no gap between a
        # question asked about a name and a read of whatever that name means by then. A name swapped in
        # that gap can still only point at another ordinary file, whose bytes this repository could have
        # written into the config anyway; what it cannot do is make the line block on a device or read
        # past the cap, because both of those are settled from the handle just below.
        $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
        if ($left -le 0) { $why = 'the deadline was spent before the open'; return $null }
        $open = [System.Threading.Tasks.Task]::Run($call.Open)
        if ([System.Threading.Tasks.Task]::WaitAny(@($open), [int] $left) -lt 0) {
            if ($script:boundedFilePending.Count -lt 8) { $script:boundedFilePending.Add([pscustomobject]@{ Kind = 'Open'; Task = $open; Path = $Path }) }
            $why = "the open did not answer inside $($limit.TimeoutMs) ms"
            return $null
        }
        $fs = if ($open.IsCompletedSuccessfully) { $open.Result } else { $null }
        if ($null -eq $fs) {
            # A file that is not there is not a refusal for the user's own config: an install without one
            # is a supported state (install.ps1 warns and carries on), and every render would otherwise
            # write the same line to the log for the life of that install. Get-Content said nothing about
            # it either. For the project file it stays a refusal, because "there is no project config" is
            # exactly the question the log was added to answer.
            $err = $open.Exception
            $base = $err.GetBaseException()
            if (-not ($Trusted -and (Test-PathAbsent $base))) {
                $why = 'it could not be opened'
            }
            return $null
        }
        $stream = Get-BoundedStreamDelegate $fs
        # From the handle: a stream that cannot seek is not an ordinary file - a FIFO, a pipe, a
        # character device. CanSeek is settled when the handle is made and costs nothing to read back;
        # the length is a call of its own, so it goes to the pool under the budget like everything else.
        # It is the length the handle reports, not one read off the path before the open.
        if (-not $fs.CanSeek) { $why = 'the handle cannot seek, so it is not an ordinary file'; return $null }
        $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
        if ($left -le 0) { $why = 'the deadline was spent before its length'; return $null }
        $length = [System.Threading.Tasks.Task]::Run($stream.Length)
        if ([System.Threading.Tasks.Task]::WaitAny(@($length), [int] $left) -lt 0) { $why = "its length did not answer inside $($limit.TimeoutMs) ms"; return $null }
        if (-not $length.IsCompletedSuccessfully) { $why = 'its length could not be read'; $err = $length.Exception; return $null }
        if ($length.Result -gt $limit.MaxBytes) { $why = "it is $($length.Result) bytes, over the $($limit.MaxBytes) byte cap"; return $null }
        # Belt and braces, and all this runtime offers against a link: a FileStream follows one, and the
        # APIs that name a handle's own target arrived in .NET 6, past the floor. So the name is asked
        # once more, and a reparse point or a directory is refused even though the handle looked ordinary.
        # The two are asked separately only so that the log can say which one it was; refusing both is
        # the one rule, and an ordinary file answers no to both tests either way. This is the trust
        # judgement and the only thing -Trusted skips; the clock is not skipped for anyone. Nothing is
        # lost by skipping it for the user's file: a directory never reaches this line, because the open
        # above refuses one with UnauthorizedAccessException (measured, and pinned by a test), and the
        # link it would refuse is a link the user made, which is a thing to follow rather than refuse.
        if (-not $Trusted) {
            $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
            if ($left -le 0) { $why = 'the deadline was spent before the attribute probe'; return $null }
            $attr = [System.Threading.Tasks.Task]::Run($call.Attributes)
            if ([System.Threading.Tasks.Task]::WaitAny(@($attr), [int] $left) -lt 0) { $why = "the attribute probe did not answer inside $($limit.TimeoutMs) ms"; return $null }
            if (-not $attr.IsCompletedSuccessfully) { $why = 'its attributes could not be read'; $err = $attr.Exception; return $null }
            if (($attr.Result -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $why = 'it is a link or a reparse point'; return $null }
            if (($attr.Result -band [System.IO.FileAttributes]::Directory) -ne 0) { $why = 'it is a directory'; return $null }
        }
        $buf = [byte[]]::new($limit.MaxBytes + 1)
        $read = 0
        while ($read -lt $buf.Length) {
            $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
            if ($left -le 0) { $why = 'the deadline was spent reading it'; return $null }
            $task = $fs.ReadAsync($buf, $read, $buf.Length - $read)
            if ([System.Threading.Tasks.Task]::WaitAny(@($task), [int] $left) -lt 0) { $why = "a read did not answer inside $($limit.TimeoutMs) ms"; return $null }
            if (-not $task.IsCompletedSuccessfully) { $why = 'it could not be read'; $err = $task.Exception; return $null }
            $n = $task.Result
            if ($n -le 0) { break }
            $read += $n
        }
        # The cap once more, in case the file grew past the length the handle reported.
        if ($read -gt $limit.MaxBytes) { $why = "it grew past the $($limit.MaxBytes) byte cap while it was being read"; return $null }
        # The bytes decoded as whatever they say they are, by the same reader Get-Content decodes with.
        # A file's encoding is the one thing about a config this script does not choose: the installer
        # writes UTF-8, but the file is the user's to edit afterwards and an editor on Windows still
        # offers UTF-16, whose bytes read as UTF-8 are a string of NULs no JSON parser will take. So a
        # config that was working has to keep working, which means following Get-Content's rule rather
        # than a rule of this script's own - and the way to be sure of that is to use the same class.
        # StreamReader over a MemoryStream is the whole of it: detectEncodingFromByteOrderMarks reads
        # the mark, switches encoding, and drops the mark from the text (nothing else does - every
        # decoder here would hand back a U+FEFF that ConvertFrom-Json will not parse past). UTF-8
        # without a mark is the fallback, which is what PowerShell 7 defaults to. Read-StdinText
        # already leans on this same detection, so the two paths into this script agree by construction.
        # No filesystem call and no copy: the MemoryStream is a window onto the buffer already read, and
        # its length is $read, so the zero padding past it cannot finish a mark that the file started.
        $ms = [System.IO.MemoryStream]::new($buf, 0, $read)
        $reader = [System.IO.StreamReader]::new($ms, [System.Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } catch {
        $why = 'the read failed'
        $err = $_.Exception
        return $null
    } finally {
        # Cleanup stays on the pool. If the close has not finished when this frame returns, retain that
        # task so the next bounded operation can observe it; no close is allowed to turn this read into a
        # filesystem wait on the render thread.
        if ($null -ne $stream) {
            try {
                $close = [System.Threading.Tasks.Task]::Run($stream.Dispose)
                if (-not $close.IsCompleted) {
                    if ($script:boundedFilePending.Count -lt 8) { $script:boundedFilePending.Add([pscustomobject]@{ Kind = 'Close'; Task = $close; Path = $Path }) }
                    else { $closeStillPending = $true }
                }
            } catch { $closeErr = $_.Exception }
        }
        # The reason is recorded here and written by the caller, once this function has returned and its
        # clock has stopped. Writing it is filesystem work of its own - a size probe, possibly a rename,
        # an open and a close - and doing that work here would put calls inside the one clock this
        # function exists to keep, and would delay the close above behind them. That is the property
        # #19 bought, and a diagnostic added for #64 is not a good enough reason to give it up. Outside,
        # Write-StatusDiag bounds itself, so handing the record out is not handing the problem on.
        if ($script:diagOn -and ($why -or $closeErr -or $closeStillPending)) {
            $script:diagBoundedRead = @{ Path = $Path; Why = $why; Err = $err; CloseErr = $closeErr; CloseStillPending = $closeStillPending }
        }
    }
}

# Writes whatever the last bounded read recorded, and forgets it. Called by the caller of
# Read-BoundedFileText immediately after it returns: see the note in that function's finally for why
# the read does not write its own record. Clearing the slot as it goes means a read that refused
# nothing cannot be reported twice, and a caller that never asks cannot leave a record for the next one.
function Write-BoundedReadDiag([string] $Label = 'config read') {
    $record = $script:diagBoundedRead
    if (-not $record) { return }
    $script:diagBoundedRead = $null
    # The flag is tested again at each call rather than once around the three, because that is the rule
    # every other call site in this script follows and test.ps1 checks for by walking the syntax tree.
    # A rule that holds everywhere is worth more than three lines of nesting saved here.
    if ($script:diagOn -and $record.Why) {
        $detail = if ($record.Err) { " ($($record.Err.GetBaseException().Message))" } else { '' }
        Write-StatusDiag "${Label}: $($record.Path) was not read: $($record.Why)$detail"
    }
    if ($script:diagOn -and $record.CloseErr) { Write-StatusDiag "${Label}: the close of $($record.Path) could not be queued: $($record.CloseErr.Message)" }
    if ($script:diagOn -and $record.CloseStillPending) { Write-StatusDiag "${Label}: the close of $($record.Path) is still pending; the pending list is full" }
}

# Applies one config file over a table and returns it. Anything missing or invalid silently falls back to
# the value already there, and each key falls back on its own: a valid order beside a broken thresholds
# keeps the order. Files are applied lowest precedence first, so what an invalid value in the project
# file falls back to is the user file's value rather than the built-in default. Both files are read
# through Read-BoundedFileText, so both are under the same deadline and the same cap; -Trusted says
# which of them is the user's own, and the reader turns that into one skipped check rather than into a
# different budget.
# A file that does not apply says so in the diagnostics log, for the same reason the bounded read does:
# falling back quietly is right, and being unable to find out why is not. The read itself already named
# the files it refused, so what is added here is what it cannot see - a file that is there and empty,
# and one whose contents are not JSON this can merge.
function Merge-StatusConfigFile([hashtable] $Cfg, [string] $Path, [switch] $Trusted) {
    try {
        if (-not $Path) { return $Cfg }
        # Both config files, the user's and the project's, are read under the same budget, and
        # CLAUDE_STATUSLINE_CONFIG_TIMEOUT_MS moves both or neither: which of them is being read is not
        # something the machine's load knows about, so a variable that raised one and not the other
        # would leave half the problem it exists for (#99).
        $text = Read-BoundedFileText $Path -Trusted:$Trusted -TimeoutMs (Get-ConfigReadTimeout)
        # The read records why it refused rather than writing it, because writing is filesystem work
        # and the read is under a clock that must not carry any. Out here that clock has stopped, so
        # the record goes to the log now.
        if ($script:diagOn) { Write-BoundedReadDiag }
        # $null is a refusal the read has already logged; an empty string is a file that is there and
        # says nothing, which nothing else would ever report.
        if (-not $text) {
            if ($script:diagOn -and $null -ne $text) { Write-StatusDiag "config merge: $Path was not applied: the file is empty" }
            return $Cfg
        }
        $j = $text | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject]) {
            if ($script:diagOn) { Write-StatusDiag "config merge: $Path was not applied: its JSON is not an object" }
            return $Cfg
        }
        # preset: a name standing for a layout, a style and every segment toggle, expanded first so that
        # every other key in this same file is written over it whatever order the file spells them in.
        # A preset therefore sits at the precedence of the file naming it: defaults, then the user file's
        # preset and the user file's own keys, then the project file's preset and the project file's own
        # keys. A project preset outranking a user toggle is the same rule as any other project key.
        # A name no preset has, or a value that is not a string, leaves everything as it was.
        $preset = Get-ConfigPreset $j.preset
        if ($null -ne $preset) {
            $Cfg.Layout = $preset.Layout
            $Cfg.Style = $preset.Style
            foreach ($n in @($Cfg.Segments.Keys)) {
                if ($preset.Segments.ContainsKey($n)) { $Cfg.Segments[$n] = $preset.Segments[$n] }
            }
        }
        foreach ($rec in Get-StatusConfigKey) {
            $v = $j.($rec.Json)
            if ($rec.Kind -eq 'Bool') {
                if ($v -is [bool]) { $Cfg[$rec.Key] = $v }
            } elseif ($v -is [string] -and $v.ToLowerInvariant() -in $rec.Allowed) {
                $Cfg[$rec.Key] = $v.ToLowerInvariant()
            }
        }
        # segments: one boolean per name, so a file naming one segment leaves the others as they were.
        $segs = $j.segments
        if ($segs -is [System.Management.Automation.PSCustomObject]) {
            foreach ($n in @($Cfg.Segments.Keys)) {
                $v = $segs.$n
                if ($v -is [bool]) { $Cfg.Segments[$n] = $v }
            }
        }
        # order: the segment names of layout one. Empty, or naming no segment, keeps the order beneath.
        $order = Read-SegmentNameList $j.order $Cfg.Segments @{}
        if ($null -ne $order -and $order.Count -gt 0) { $Cfg.Order = $order }
        # rows: two arrays of names for layout two, read against one seen set so a segment sits on one
        # row only. Anything but exactly two arrays, or two rows naming nothing, keeps the rows beneath.
        $rows = $j.rows
        if ($rows -is [array] -and $rows.Count -eq 2) {
            $seen = @{}
            $row1 = Read-SegmentNameList $rows[0] $Cfg.Segments $seen
            $row2 = Read-SegmentNameList $rows[1] $Cfg.Segments $seen
            if ($null -ne $row1 -and $null -ne $row2 -and ($row1.Count + $row2.Count) -gt 0) { $Cfg.Rows = @($row1, $row2) }
        }
        # right: the segment names pushed flush against the right edge of the first line, read with the
        # same rules order and rows are read with - lower-cased, known to the registry, first place wins,
        # anything else skipped - and a value that is not an array leaves the group beneath it.
        # THE EMPTY LIST IS KEPT HERE and is not a fall-back, which is the one place this key parts from
        # `order` and `rows`. Those two fall back from an empty list because a line naming no segment is
        # not a layout and there is nothing a file could have meant by it; an empty right group is the
        # built-in default and a real thing to ask for, and keeping it is what lets a project file take
        # back a group the user file asked for.
        $right = Read-SegmentNameList $j.right $Cfg.Segments @{}
        if ($null -ne $right) { $Cfg.Right = $right }
        # thresholds: warn and bad, whole numbers 0 to 100 with warn at or below bad, for the context
        # meter on a standard window and for the rate limits. A whole number written as 20.0 counts, the
        # way Get-PayloadNumber reads a count, since a config written by another tool can spell it so.
        # Either value wrong keeps both as they were.
        $t = $j.thresholds
        if ($t -is [System.Management.Automation.PSCustomObject]) {
            $w = Get-FiniteNumber $t.warn
            $b = Get-FiniteNumber $t.bad
            if ($null -ne $w -and $null -ne $b -and $w -eq [math]::Floor($w) -and $b -eq [math]::Floor($b) -and $w -ge 0 -and $b -le 100 -and $w -le $b) {
                $Cfg.Thresholds = @{ Warn = [int] $w; Bad = [int] $b }
            }
        }
        # alarm: the two percentages at or above which the model segment turns red, one for the context
        # window and one for the rate limits. Unlike thresholds these are read one at a time, the way the
        # git keys are, because they are not a pair that has to agree: a file naming only context leaves
        # limits where it was, and a value that is not a whole number keeps the value beneath it. 0 turns
        # that alarm off outright, and a negative clamps to it. The top of the range is Int32's own end
        # rather than 100, so a value above 100 is kept as written and fires only if the payload reports
        # a figure that high: a context window never does, because the meter clamps to 100, but a rate
        # limit can, because a limit really at 105% is left unclamped to say so. Clamping the level to
        # 100 instead would turn it into an alarm at every full window.
        $al = $j.alarm
        if ($al -is [System.Management.Automation.PSCustomObject]) {
            $Cfg.Alarm.Context = Get-ConfigInteger $al.context $Cfg.Alarm.Context 0 ([int]::MaxValue)
            $Cfg.Alarm.Limits = Get-ConfigInteger $al.limits $Cfg.Alarm.Limits 0 ([int]::MaxValue)
        }
        # quiet: the smallest value a segment is worth building at - dollars for cost, percent for
        # context and limits. Any finite number counts, fractions included, because a cost threshold is
        # money rather than a count; a negative is clamped to 0, which is the default and hides nothing.
        # Merged one name at a time, so a typo in one name cannot disturb the other two, and a quiet
        # that is not an object at all keeps all three.
        $q = $j.quiet
        if ($q -is [System.Management.Automation.PSCustomObject]) {
            foreach ($n in @($Cfg.Quiet.Keys)) {
                $v = Get-FiniteNumber $q.$n
                if ($null -ne $v) { $Cfg.Quiet[$n] = [math]::Max(0.0, $v) }
            }
        }
        # icons: icon name to a hex code point string, merged one name at a time. Only a known name with
        # a code point Read-CodePoint accepts is kept, as name to integer; every other entry leaves the
        # glyph beneath alone. The two names the constants shorten are accepted in either spelling.
        $ic = $j.icons
        if ($ic -is [System.Management.Automation.PSCustomObject]) {
            $known = Get-IconDefault
            $alias = @{ ctx = 'context'; limit = 'limits' }
            foreach ($p in $ic.PSObject.Properties) {
                $n = $p.Name.ToLowerInvariant()
                if ($alias.ContainsKey($n)) { $n = $alias[$n] }
                $cp = Read-CodePoint $p.Value
                if ($known.ContainsKey($n) -and $null -ne $cp) { $Cfg.Icons[$n] = $cp }
            }
        }
        # ---- git: probe timeout and cache ----
        # Whole numbers are clamped to their range; a key of the wrong type keeps the value beneath it,
        # and a git value that is not an object keeps all three.
        $g = $j.git
        if ($g -is [System.Management.Automation.PSCustomObject]) {
            $Cfg.Git.TimeoutMs = Get-ConfigInteger $g.timeoutMs $Cfg.Git.TimeoutMs 100 10000
            $Cfg.Git.CacheSeconds = Get-ConfigInteger $g.cacheSeconds $Cfg.Git.CacheSeconds 0 300
            if ($g.cache -is [bool]) { $Cfg.Git.Cache = $g.cache }
        }
    } catch {
        if ($script:diagOn) { Write-StatusDiag "config merge: $Path was not applied: $($_.Exception.Message)" }
        return $Cfg
    }
    return $Cfg
}

# What -Config names, as a filesystem path, or $null when it does not name one.
#
# This is the one place a path a person typed is turned into a path a filesystem call can take, and it
# exists because those are not the same thing in PowerShell. Get-Content reads a relative name against
# the SESSION's location; every call in the bounded read reads it against the PROCESS's working
# directory, and Set-Location moves the first and leaves the second where the process started. The
# difference is not only relative names: `C:statusline.json` is drive-relative and `IsPathRooted` calls
# it rooted, so a test on that would let exactly the confusing cases through. So the name is resolved
# unconditionally, here, once, at the edge - not inside the read, where it would make -Trusted mean two
# things at once.
#
# GetUnresolvedProviderPathFromPSPath resolves rather than probes: it maps a PowerShell path to a
# provider path with no filesystem call at all, which is what lets it sit in front of the clock. A name
# it will not map - `nodrive:statusline.json`, a drive that does not exist - is REFUSED here rather than
# handed on as it stands. Handing it on was worse than it looks: on Windows, File.OpenRead of a name
# with a colon in it opens an alternate data stream of a file in the working directory, which Test-Path
# on the old path would never have found. A refusal falls back to the built-in defaults and says so in
# the log, which is what every other unusable config does.
function Resolve-ConfigPath([string] $Path) {
    if (-not $Path) { return $null }
    $resolved = try { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } catch { $null }
    if (-not $resolved) { return $null }
    return $resolved
}

# The config a render runs on: the built-in defaults, the user file, then the project file when the
# payload named a project directory holding .claude\statusline.json. The merge is per key, so a project
# file of {"layout": "two"} keeps every user toggle. A project directory that is missing, holds no
# .claude\statusline.json, or holds an unreadable one leaves the config below it exactly as it was. That
# file arrives with the repository rather than from the user, so it is read as bounded untrusted input.
# The user's file is bounded too, and read as trusted: a home directory can be on a dead share as easily
# as a project directory can, but nobody chose that path for the user. Either file falling back is the
# same fall-back it always was - the values beneath it stand, and nothing is said on the line - so a
# user config that is missing, empty, oversized, too slow or invalid all land where an invalid one
# always landed, on the built-in defaults.
# $ProjectDir is untyped and gated here rather than declared [string]: a payload spells project_dir
# however it likes, and a [string] parameter would join an array into a path instead of rejecting it.
# The caller passes it only when -Config named no file, so an explicit config renders the same whatever
# directory the payload names.
function Read-StatusConfig([string] $Path, $ProjectDir) {
    $cfg = Merge-StatusConfigFile (Get-DefaultStatusConfig) $Path -Trusted
    if ($ProjectDir -isnot [string] -or -not $ProjectDir) { return $cfg }
    # No Test-Path on the project directory on the way in. It would be a filesystem call on a path the
    # repository chose, outside the one budget below, which is the whole thing that budget is for; a
    # directory that is not there is refused by the bounded read like anything else it cannot open.
    # Join-Path only joins strings, so the first call to touch a disk is inside Read-BoundedFileText.
    try { return Merge-StatusConfigFile $cfg (Join-Path $ProjectDir '.claude' 'statusline.json') } catch {
        if ($script:diagOn) { Write-StatusDiag "project config: nothing was read under $ProjectDir - $($_.Exception.Message)" }
        return $cfg
    }
}

# Colour table. Plain style uses SGR codes drawn straight onto whatever the terminal's background is;
# powerline uses 256-colour foreground/background pairs, so a block paints its own ground and only the
# arrow at its edge meets the terminal's.
#
# PALETTE IS A SEPARATE AXIS FROM STYLE, and the two are separate because they answer different
# questions. `style` is the SHAPE of a line - a chevron between coloured words, a run of solid blocks,
# or the same shape drawn in characters a plain font has. `palette` is the COLOUR NUMBERS those shapes
# are drawn with, and the only thing it depends on is whether the terminal's background is dark or
# light. Every one of the six combinations is meant: `ascii` with `light` is the ascii shapes in the
# light numbers, and it cannot break the ascii promise, because an SGR code is digits and semicolons
# and Get-VisibleWidth strips it before anything is measured.
#
# `dark` is the table this script has always had and is what an unrecognised name falls back to, so a
# config file written before this parameter existed - and every caller inside this script that does not
# pass one - renders the same bytes it did.
#
# HOW THE NUMBERS WERE CHOSEN. Not by eye: the rules below are arithmetic, checked in test.ps1 against
# the grounds a terminal actually has. The ratios are WCAG 2.1 relative luminance, the DISTANCES are
# straight-line distance in sRGB, and the colour indices are the xterm 6x6x6 cube on the levels
# 0, 95, 135, 175, 215, 255 with a grey ramp at 8 + 10n, so anyone can work out the hex for a number
# here and check a figure by hand.
#   1. A plain-style foreground clears 4.5:1 on both light grounds (#FFFFFF and an off-white #F5F5F5).
#      The worst is light warn, 94 (#875F00), at 5.25. All seven light codes are 256-colour codes
#      rather than the basic sixteen on purpose: the sixteen are whatever the terminal's scheme says
#      they are, which is exactly the thing that goes wrong on a light theme.
#   2. A powerline block's own text on its own background clears 4.5:1. The light table's worst is
#      folder at 9.14; the dark table's worst is model, 231 on 31, at 4.13, which is older than the
#      rule and is exempted BY NAME in the test so the debt stays visible rather than lowering the bar
#      for the other six.
#   3. A block's background clears its own table's bar against the terminal's own ground, because the
#      trailing arrow paints that background as a FOREGROUND on the terminal and every block edge is
#      the same boundary. Dark's bar is 1.7:1 and its worst is dim, 238, at 2.01 against Campbell.
#      LIGHT'S BAR IS 1.25:1, worst model, 51, at 1.25, and the two differ because of #89 rather than
#      by neglect. Seven backgrounds each 1.10:1 from the next - rule 4(c) - need a luminance span of
#      1.7716:1. Rule 4(a) floors every light background at 0.398 relative luminance, because the
#      BRIGHTEST of the markers - muted 24, #005F87, at 0.0993 - has to clear 3:1 inside every one of
#      them, and a 1.7 bar here ceilinged them at 0.568: a band of 1.3786:1, in which at most four of
#      the seven can ever sit 1.10 apart. That is arithmetic and not a tuning problem, so no assignment
#      exists - not in the cube, and not in truecolour either, since the band is set by the rules
#      rather than by the palette's 216 values. One of the three bars had to give, and this is the one
#      whose cost is carried by a saturated hue rather than by a marker BOTH tables share: the block
#      that sets 1.25 is model #00FFFF, whose edge against white is chroma where its luminance is
#      nearly white's, and the palest NEUTRAL in the table is still dim #D0D0D0 at 1.54. Rule 3 ALSO
#      HOLDS EVERY BACKGROUND 80 sRGB from its terminal ground: light dim is the minimum at 81.4, so
#      a pale neutral cannot leave an almost-white edge behind.
#   4. THE THREE THINGS AN INLINE MARKER HAS TO DO. A marker - `92% cached`, `1M`, `+156`, an arrow, a
#      branch count - is drawn INSIDE a block by Format-Inline, beside that block's own text. So it has
#      to clear three bars at once, and #82 is the issue that found out what happens when only one of
#      them is checked:
#        (a) 3:1 against the block's BACKGROUND, or it is invisible. `cached` 244 inside the model
#            block was 1.05:1 - one colour drawn on itself, for all a reader could tell.
#        (b) at least 85 sRGB distance from the block's own TEXT, or it merges with the figure it
#            qualifies. This is a distance and not a ratio on purpose: see below.
#        (c) and, for the blocks themselves rather than the markers, every ordered pair of block
#            backgrounds stays 1.10:1 apart in luminance and 40 apart in distance - in BOTH tables
#            since #89 - because the arrow between two blocks is the left block's background painted
#            as a foreground on the right one's. Two blocks of equal luminance make that arrow
#            disappear even when the two colours are plainly different side by side. The dark table's
#            worst pair is dim/branch at 1.104 and model/folder at exactly 40.0; the light table's is
#            bad/dim at 1.101 and bad/branch at 56.6, and the light half of this rule is what moved
#            all seven light backgrounds and cost rule 3 its bar.
#
# WHY THERE ARE TWO MARKER COLUMNS. (a) and (b) pull in opposite directions, and on a dark block they
# pull hard enough that no single colour can do both. A dark block is dark, so a marker clearing 3:1
# against it must be BRIGHT - inside the model block, 31 (#0087AF), it must be above 0.71 relative
# luminance, which is nearly white. But the block's own text is white. Anything that clears (a) there
# is within 1.38:1 of the text, so (b) CANNOT be a luminance ratio on a dark block; it has to be
# colour distance, and the marker has to carry a hue. On the warn block the arithmetic is the mirror
# image: the block is light and its text is black, so a marker must be DARK to clear (a), and then (b)
# comes free in luminance. One colour cannot be both bright and dark, so each marker carries two:
# `Light` for a block whose own text is light, `Dark` for a block whose own text is dark. Each role
# names which column it takes in `Ink`, and Format-Inline looks the marker up by it. A palette carries
# only the columns its own roles ask for, so there is no unused colour in either table: every role in
# the light table has dark ink, so the light table has a `Dark` column and nothing else.
#
# WHAT THAT COST, STATED PLAINLY. On a dark block a marker cannot be quiet, because quiet means close
# to the background and (a) forbids it; and it cannot be grey, because grey means close to white text
# and (b) forbids it. So the dark table's `Light` column is bright and hued where it used to be mid
# grey: `track` and `cached` are pale cyans rather than 245/244, and `muted` is a brighter cyan than
# 152. `removed` is the one that loses something real. A red cannot clear (a) inside the model block:
# with red at full, green has to reach 215 and blue 135 before the luminance is high enough, and that
# colour is #FFD787 - an apricot, and the reddest thing that exists up there. So the dark `Light`
# `removed` is 222, warm rather than red, and the true red 124 survives in the `Dark` column where the
# warn block's light background makes it possible. added stays 46, the green it always was.
# Role for role the two tables still line up: ok is the green of inline added, bad the red of removed,
# and muted is the model's own colour at normal intensity, which is why its code opens with 22 in both.
# The two tables' `Dark` columns are the same five numbers, and deliberately so - a dark marker on a
# light block is the same problem in both palettes, so it has the same answer.
#
# THE MARKERS' PLAIN CODES, AND WHY ONLY TWO OF THEM MOVED (#88). Everything above is about a marker
# inside a block. In plain style there is no block: the marker is drawn on the terminal's own ground,
# so the only bar that means anything is the ratio against that ground - rule 1's bar, 4.5:1 - and the
# only colours that can be held to it are the ones this table can name a hex for. `track` and `cached`
# were `90`, bright black, which is not a colour this table knows: it is whatever the scheme says, and
# on Solarized Dark that is #586E75 on a #002B36 ground, 2.79:1. The `92% cached` suffix and the
# `+3 ~1 ?2` branch counts were under even the 3:1 in-block bar on the shipped default style. Both are
# 246 (#949494) now: the LOWEST index on the grey ramp that clears 4.5 on Campbell (6.45) and on
# Solarized Dark (4.95) alike, chosen low on purpose so the line moves as little as it can while still
# being a colour that can be promised. Both tables' plain marker codes are asserted in test.ps1 now.
# `added` 32, `removed` 31 and `muted` 22;36 STAY on the basic sixteen, and so do all seven of the
# dark ROLES, including `dim` 90 - the chevron. Those are hues rather than greys and they are the
# line's own text rather than a marker beside it, so replacing them is a redesign of what a dark plain
# line looks like, not a repair; a scheme's own green is also better tuned to that scheme's ground
# than one index picked here. That larger change is deliberately not folded in here. `dim` 90 is the
# piece of it with a number: 2.79:1 on Solarized Dark, the same figure the two markers had, tracked as
# #111. It is not simply the markers' answer applied again - a quiet grey close enough to 246 to be
# readable is within a few sRGB steps of the markers drawn inside those same segments, which is rule
# 4b's problem over again, so `dim` and the marker grey have to be chosen as a pair.
#
# WHAT 246 COSTS, ON THE ONE CONFIGURATION IT IS NOT FOR. `dark` is the default, so a reader on a LIGHT
# terminal who never set `palette` gets this table anyway, and there 246 is a fixed 3.03:1 on white and
# 2.81:1 on Solarized Light's #FDF6E3. `90` on that reader's screen was not better so much as unknown:
# a scheme drawing brightBlack #767676 gave 4.54:1 on white, one drawing #93A1A1 gave 2.48:1 - the
# same coin toss this whole table exists to stop, landing the other way up. So the change trades a
# figure nobody could state for one anybody can, and the honest reading is that a dark table on a light
# ground is out of contrast either way. THE REMEDY IS THE PALETTE KEY, not a compromise colour that
# clears neither ground: `"palette": "light"`, or `install.ps1 -DetectTheme`, which reads Windows
# Terminal's background and writes the key. Every bar in this note is measured against the ground its
# own table is for, and a table measured against both would be a table that reads well on neither.
#
# THE SECOND SHADE, AltBg AND AltSgr (#106). Seven distinct role colours are still one colour where the
# LAYOUT puts two segments of the same role side by side, and the shipped second row does exactly that:
# context, cache and limits are all `ok` while nothing is warning, then cost, clock and lines are all
# `dim`. Three blocks of one background are one band with an invisible arrow inside it; in plain style
# they are one foreground code with only the chevron between them. Neither the palette nor the layout
# can see that on its own - the palette does not know the order and the layout does not know the
# colours - so the roles a VALUE moves between use the second shade their table supplies, and Format-Line
# hands it to a block whose immediate predecessor on the line carries the same role.
# THE SHADE MOVES THE BACKGROUND AND NEVER THE BLOCK'S TEXT, which is not a preference: a segment's
# text is built before there is a line, so the markers inside it were already chosen by the role's ink
# and already close their runs by handing that role's own foreground back. A second foreground would
# have to be threaded back into text that is finished. So `Fg` and `Ink` are the role's either way, and
# what has to hold instead is that every marker still clears its floors against the second background -
# which is measured, in test.ps1, exactly as it is for the first.
# THE ABSENCES, EACH MEASURED RATHER THAN CHOSEN:
#   model, folder and branch have no second shade because each is the role of exactly ONE segment, so
#     no line can put two of them side by side.
#   dark `dim` has no second BACKGROUND. Its block is a grey wedged between its own light text at 250
#     and the terminal's ground below, which leaves a band of about 0.041 to 0.073 in relative
#     luminance - and no NEUTRAL colour in the 256-colour cube sits in it 40 sRGB from #444444. Its
#     joints take Format-Line's divider instead, which is the whole reason that fallback exists.
#   light `ok` has no second PLAIN code, the mirror-image case: every green in the cube 40 sRGB from
#     #005F00 is too light to hold 4.5:1 on a white ground, so that pair keeps the chevron it had.
#   THE LIGHT TABLE HAS NO SECOND BACKGROUND AT ALL since #89, and that is a whole column absent rather
#     than a cell. Rule 4(c) holds every pair of backgrounds a line can paint to 1.10:1, alternates
#     included, and the seven light bases already spend the entire band rules 4(a) and 3 leave them:
#     1.7716:1 out of 1.8750:1. Their widest interior gap is 1.1118 where an eighth value needs 1.21 to
#     sit between two of them, there is 1.0204 of headroom below folder, and a shade 1.10 above model
#     would be 1.1399:1 against white where rule 3 asks 1.25. An alternate run costs exactly one more
#     1.10 step however long it is, since two alternates never touch, so the light rule 3 bar at which
#     the first one could fit is 1.20269 - and at 1.20 the cube still offers nothing for any of the
#     seven. Every repeated light role takes the divider, and here that is the better joint rather than
#     a consolation: a chevron in the block's own ink is 9.14:1 or better on a light block, where the
#     four shades #106 shipped measure 1.008 to 1.022 against the new bases, which is precisely the
#     invisible arrow #89 exists to close.
# The plain alternates are 256-colour indices in BOTH tables even though the dark table's seven base
# codes are the basic sixteen. A colour chosen now has no reason to be a theme's own green, and one
# concrete reason not to be: Solarized Dark maps the bright half of the sixteen onto greys, so `32`
# beside `92` there would be a green beside a grey rather than a green beside a lighter green. The
# `dim` alternate 251 is also 86.6 sRGB from the 246 the markers inside those same segments are drawn
# in, which is #111's constraint honoured in advance - #111 itself, the base `dim` 90, is untouched.
function Get-Palette([string] $Palette = 'dark') {
    if ($Palette -eq 'light') {
        return @{
            Roles = @{
                model  = @{ Sgr = '1;38;5;24'; Fg = 16; Bg = 51;  Ink = 'Dark' }
                ok     = @{ Sgr = '38;5;22';   Fg = 16; Bg = 76;  Ink = 'Dark' }
                warn   = @{ Sgr = '38;5;94';   Fg = 16; Bg = 221; Ink = 'Dark'; AltSgr = '38;5;58' }
                bad    = @{ Sgr = '38;5;124';  Fg = 16; Bg = 218; Ink = 'Dark'; AltSgr = '38;5;88' }
                dim    = @{ Sgr = '38;5;240';  Fg = 16; Bg = 252; Ink = 'Dark'; AltSgr = '38;5;237' }
                folder = @{ Sgr = '38;5;25';   Fg = 16; Bg = 110; Ink = 'Dark' }
                branch = @{ Sgr = '38;5;90';   Fg = 16; Bg = 213; Ink = 'Dark' }
            }
            Inline = @{
                added   = @{ Sgr = '38;5;22';    Dark = 22 }
                removed = @{ Sgr = '38;5;124';   Dark = 124 }
                track   = @{ Sgr = '38;5;240';   Dark = 240 }
                muted   = @{ Sgr = '22;38;5;24'; Dark = 24 }
                cached  = @{ Sgr = '38;5;240';   Dark = 238 }
            }
        }
    }
    return @{
        Roles = @{
            model  = @{ Sgr = '1;36'; Fg = 231; Bg = 31;  Ink = 'Light' }
            ok     = @{ Sgr = '32';   Fg = 231; Bg = 28;  Ink = 'Light'; AltBg = 22;  AltSgr = '38;5;114' }
            warn   = @{ Sgr = '33';   Fg = 16;  Bg = 178; Ink = 'Dark';  AltBg = 214; AltSgr = '38;5;221' }
            bad    = @{ Sgr = '31';   Fg = 231; Bg = 160; Ink = 'Light'; AltBg = 124; AltSgr = '38;5;210' }
            dim    = @{ Sgr = '90';   Fg = 250; Bg = 238; Ink = 'Light'; AltSgr = '38;5;251' }
            folder = @{ Sgr = '34';   Fg = 231; Bg = 25;  Ink = 'Light' }
            branch = @{ Sgr = '35';   Fg = 231; Bg = 90;  Ink = 'Light' }
        }
        Inline = @{
            added   = @{ Sgr = '32';        Light = 46;  Dark = 22 }
            removed = @{ Sgr = '31';        Light = 222; Dark = 124 }
            track   = @{ Sgr = '38;5;246';  Light = 123; Dark = 240 }
            muted   = @{ Sgr = '22;36';     Light = 87;  Dark = 24 }
            cached  = @{ Sgr = '38;5;246';  Light = 86;  Dark = 238 }
        }
    }
}

# Resting segment colours belong only to the main line. The agent panel uses role colours, so
# keeping this table apart leaves Get-Palette as the exact shared roles-and-inline helper.
function Get-SegmentPalette([string] $Palette = 'dark') {
    if ($Palette -eq 'light') {
        return @{
            model   = @{ Sgr = '38;5;24';  Fg = 16; Bg = 75;  Ink = 'Dark' }
            context = @{ Sgr = '38;5;25';  Fg = 16; Bg = 145; Ink = 'Dark' }
            cache   = @{ Sgr = '38;5;90';  Fg = 16; Bg = 213; Ink = 'Dark' }
            cost    = @{ Sgr = '38;5;23';  Fg = 16; Bg = 40;  Ink = 'Dark' }
            clock   = @{ Sgr = '38;5;22';  Fg = 16; Bg = 43;  Ink = 'Dark' }
            time    = @{ Sgr = '38;5;58';  Fg = 16; Bg = 113; Ink = 'Dark' }
            lines   = @{ Sgr = '38;5;17';  Fg = 16; Bg = 148; Ink = 'Dark' }
            limits  = @{ Sgr = '38;5;61';  Fg = 16; Bg = 117; Ink = 'Dark' }
            badges  = @{ Sgr = '38;5;60';  Fg = 16; Bg = 186; Ink = 'Dark' }
            pr      = @{ Sgr = '38;5;95';  Fg = 16; Bg = 220; Ink = 'Dark' }
            folder  = @{ Sgr = '38;5;26';  Fg = 16; Bg = 82;  Ink = 'Dark' }
            branch  = @{ Sgr = '38;5;160'; Fg = 16; Bg = 120; Ink = 'Dark' }
        }
    }
    return @{
        model   = @{ Sgr = '38;5;39';  Fg = 231; Bg = 54;  Ink = 'Light' }
        context = @{ Sgr = '38;5;40';  Fg = 231; Bg = 20;  Ink = 'Light' }
        cache   = @{ Sgr = '38;5;69';  Fg = 231; Bg = 55;  Ink = 'Light' }
        cost    = @{ Sgr = '38;5;70';  Fg = 231; Bg = 90;  Ink = 'Light' }
        clock   = @{ Sgr = '38;5;104'; Fg = 231; Bg = 239; Ink = 'Light' }
        time    = @{ Sgr = '38;5;105'; Fg = 231; Bg = 23;  Ink = 'Light' }
        lines   = @{ Sgr = '38;5;137'; Fg = 231; Bg = 24;  Ink = 'Light' }
        limits  = @{ Sgr = '38;5;138'; Fg = 231; Bg = 126; Ink = 'Light' }
        badges  = @{ Sgr = '38;5;170'; Fg = 231; Bg = 127; Ink = 'Light' }
        pr      = @{ Sgr = '38;5;171'; Fg = 231; Bg = 26;  Ink = 'Light' }
        folder  = @{ Sgr = '38;5;201'; Fg = 231; Bg = 128; Ink = 'Light' }
        branch  = @{ Sgr = '38;5;202'; Fg = 231; Bg = 242; Ink = 'Light' }
    }
}

# Resolves the colour a line will paint. Segment tint owns a resting colour for each named segment, but
# warning and bad roles remain semantic states: a threshold, cold cache, conflict, or alarm still turns
# yellow or red rather than merely becoming that segment's resting hue.
function Get-TintColour($PaletteTable, [string] $Segment, [string] $Role, [string] $Tint = 'role', [string] $Palette = 'dark') {
    $segments = Get-SegmentPalette $Palette
    if ($Tint -eq 'segment' -and $Role -notin @('warn', 'bad') -and $Segment -and $segments.ContainsKey($Segment)) {
        return $segments[$Segment]
    }
    return $PaletteTable.Roles[$Role]
}

function Get-StatuslineRgb([int] $Index) {
    if ($Index -ge 232) { $v = 8 + 10 * ($Index - 232); return @($v, $v, $v) }
    $levels = @(0, 95, 135, 175, 215, 255)
    $n = $Index - 16
    return @($levels[[math]::Floor($n / 36)], $levels[[math]::Floor(($n % 36) / 6)], $levels[$n % 6])
}
function Get-StatuslineLuminance($Rgb) {
    $linear = foreach ($v in $Rgb) { $s = $v / 255; if ($s -le 0.03928) { $s / 12.92 } else { [math]::Pow((($s + 0.055) / 1.055), 2.4) } }
    return 0.2126 * $linear[0] + 0.7152 * $linear[1] + 0.0722 * $linear[2]
}
function Test-StatuslineJointClear([int] $Left, [int] $Right) {
    $leftRgb = Get-StatuslineRgb $Left
    $rightRgb = Get-StatuslineRgb $Right
    $leftLum = Get-StatuslineLuminance $leftRgb
    $rightLum = Get-StatuslineLuminance $rightRgb
    $ratio = ([math]::Max($leftLum, $rightLum) + 0.05) / ([math]::Min($leftLum, $rightLum) + 0.05)
    $distance = [math]::Sqrt((($leftRgb[0] - $rightRgb[0]) * ($leftRgb[0] - $rightRgb[0])) + (($leftRgb[1] - $rightRgb[1]) * ($leftRgb[1] - $rightRgb[1])) + (($leftRgb[2] - $rightRgb[2]) * ($leftRgb[2] - $rightRgb[2])))
    return $ratio -ge 1.10 -and $distance -ge 40
}

# A foreground-only colour change inside a segment that restores the segment's own foreground afterwards,
# so a powerline background is never interrupted by a reset.
# In powerline style the marker is picked by the BLOCK'S INK - which of the two columns in the Inline
# table this block takes - because a marker has to clear the block's background and stay apart from the
# block's own text at the same time, and on a dark block those two pull in opposite directions. See the
# note over Get-Palette. The role is already in hand here, so the choice costs one lookup and no caller
# has to know about it. Plain style draws on the terminal's own ground, where there is no block and no
# block text, so it keeps the single Sgr code it always had.
function Format-Inline([string] $Role, [string] $Text, [string] $SegmentRole, [string] $Style, [string] $Palette = 'dark', [string] $Segment = '', [string] $Tint = 'role') {
    $pal = Get-Palette $Palette
    $colour = Get-TintColour $pal $Segment $SegmentRole $Tint $Palette
    if ($Style -eq 'powerline') {
        $ink = $colour.Ink
        return "`e[38;5;$($pal.Inline[$Role][$ink])m$Text`e[38;5;$($colour.Fg)m"
    }
    return "`e[$($pal.Inline[$Role].Sgr)m$Text`e[$($colour.Sgr)m"
}

# Wraps text in an OSC 8 hyperlink, ESC ] 8 ; ; url ESC \ text ESC ] 8 ; ; ESC \, which a terminal that
# understands it (Windows Terminal on ctrl-click) opens. The helper owns its own type gate, so it takes
# the raw payload value: the text comes back unchanged unless the url is a string (a cast would join an
# array into one that passes), at most 2083 characters (the classic browser cap), free of whitespace and
# of any Unicode control character (category Cc: the C0 range, DEL and the C1 range, where U+009B,
# U+009C and U+009D are CSI, ST and OSC in their 8-bit forms), and parses as an absolute http or https
# URI whose scheme this allows. So nothing a payload puts there can end the sequence early or put a
# stray escape on the line.
# Three schemes: http and https for the pull request and the branch page, and file for the folder, which
# is how a terminal is told to open a directory. file carries one rule the other two do not need - the
# authority has to be empty. file:///C:/x is a path on this machine; file://server/share is a UNC path,
# and a click on one reaches out over SMB to a machine the payload named, which is a request the person
# at the keyboard did not make. Everything else is refused as it always was.
# The link goes into the segment's Text, so Format-Line wraps it in the segment's colour codes in either
# style: OSC 8 carries no SGR state, so a powerline background runs on through it, and Get-VisibleWidth
# strips it before measuring.
function Format-Link($Url, [string] $Text) {
    if ($Url -isnot [string] -or $Url.Length -gt 2083 -or $Url -match '[\s\p{Cc}]') { return $Text }
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref] $uri)) { return $Text }
    if ($uri.Scheme -eq 'file') {
        if ($uri.Host) { return $Text }
    } elseif ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $Text }
    return "`e]8;;$Url`e\$Text`e]8;;`e\"
}

# Renders an ordered list of segment records as one line in the given style and palette. The two are
# read independently: $Style decides the shape - blocks, a chevron or an ascii divider - and $Palette
# decides only which numbers go into the colour codes, so every pairing of the three styles and the two
# palettes is a line this function draws.
# It is also where two neighbours of the SAME role are told apart, in all three styles: the second one
# takes the role's alternate shade, and where the role has none the powerline joint is drawn as a
# visible divider instead of an arrow of one colour on itself. See the note over Get-Palette.
function Format-Line($Segments, [string] $Style, [string] $Palette = 'dark', [string] $Tint = 'role') {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s) } }
    if ($segs.Count -eq 0) { return '' }
    $pal = Get-Palette $Palette
    # WHICH BLOCKS TAKE THEIR ROLE'S SECOND SHADE, decided here and from the records this function was
    # handed, because this is the only place the question can be answered. A line can be missing the
    # cache block, the lines block or the pull request, so which segments end up next to each other is
    # not a property of the registry; it is a property of this payload, this config and this width.
    # A block whose immediate predecessor carries the same role takes the alternate, and the flag flips
    # back for the one after it, so a run of three reads base, alt, base and two alternate blocks can
    # never touch - which is what lets the palette leave the alt-against-alt pairs unmeasured.
    $alt = [bool[]]::new($segs.Count)
    for ($i = 1; $i -lt $segs.Count; $i++) {
        $previous = Get-TintColour $pal $segs[$i - 1].Name $segs[$i - 1].Role $Tint $Palette
        $current = Get-TintColour $pal $segs[$i].Name $segs[$i].Role $Tint $Palette
        $alt[$i] = $current.Bg -eq $previous.Bg -and -not $alt[$i - 1]
    }
    # The soft separator belongs to every style: ASCII chooses its '>' here and the other styles share the Nerd Font glyph.
    $divider = if ($Style -eq 'ascii') { '>' } else { [char]::ConvertFromUtf32(0xE0B1) }
    if ($Style -eq 'powerline') {
        $arrow = [char]::ConvertFromUtf32(0xE0B0)
        # The background each block actually paints, settled before anything is drawn: the arrow between
        # two blocks is made of both of their backgrounds, so the second one has to be known already.
        $bg = [int[]]::new($segs.Count)
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $c = Get-TintColour $pal $segs[$i].Name $segs[$i].Role $Tint $Palette
            $bg[$i] = if ($alt[$i] -and $null -ne $c.AltBg) { $c.AltBg } else { $c.Bg }
        }
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $s = $segs[$i]
            $c = Get-TintColour $pal $s.Name $s.Role $Tint $Palette
            $bold = if ($s.Bold) { '1;' } else { '' }
            [void] $sb.Append("`e[0;${bold}48;5;$($bg[$i]);38;5;$($c.Fg)m $($s.Text) ")
            if ($i -lt $segs.Count - 1) {
                if (-not (Test-StatuslineJointClear $bg[$i] $bg[$i + 1])) {
                    # TWO NEIGHBOURS WHOSE RESOLVED BACKGROUNDS FAIL EITHER JOINT FLOOR: they may
                    # be identical, too near in luminance, or too near in sRGB. An arrow here would
                    # disappear into the pair, so the joint is drawn as the thin separator in the left
                    # block's own ink instead. Thin rather than the solid arrow, since a solid triangle
                    # in the text colour reads as a segment of its own; and the ink is already known to
                    # clear the background, because it is what the block writes in. The rule is on the
                    # RENDERED backgrounds rather than on roles, so it covers alternation gaps, semantic
                    # overrides, and any future pair that resolves too close for an arrow.
                    [void] $sb.Append("`e[38;5;$($c.Fg);48;5;$($bg[$i])m$divider")
                } else {
                    [void] $sb.Append("`e[38;5;$($bg[$i]);48;5;$($bg[$i + 1])m$arrow")
                }
            } else {
                [void] $sb.Append("`e[0m`e[38;5;$($bg[$i])m$arrow`e[0m")
            }
        }
        return $sb.ToString()
    }
    # Powerline is not offered an ASCII block substitute: its look is a solid background, so ASCII renders
    # like plain instead. Its '>' and plain's Nerd Font glyph were both selected above.
    # The divider's colour comes from the palette's dim role rather than a literal 90, which is what it
    # used to be. The dark table spells that role 90, so this line renders the same bytes it always did;
    # on a light terminal 90 is a pale grey on a pale ground and the chevron would be the one mark on
    # the line that did not follow the theme.
    $sep = " `e[$($pal.Roles.dim.Sgr)m$divider`e[0m "
    $parts = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $s = $segs[$i]
        $c = Get-TintColour $pal $s.Name $s.Role $Tint $Palette
        if (-not ($alt[$i] -and $c.AltSgr)) { $parts.Add("`e[$($c.Sgr)m$($s.Text)`e[0m"); continue }
        # THE SEGMENT'S OWN CODE, INSIDE ITS TEXT AS WELL AS IN FRONT OF IT. Format-Inline closes every
        # marker it draws by handing the segment's colour back, and it chose that colour when the text
        # was built - before this line existed and before anything knew this segment would be the second
        # of its role. Left alone, the text after the first marker would revert to the base code and the
        # segment would be two colours. The run to move is exactly the one Format-Inline emits, and
        # String.Replace is ordinal, so nothing but that escape can match. This couples the replacement to
        # Format-Inline's exact plain hand-back bytes; the renderer assertions `plain same role: muted marker
        # hands the alternate back after its 22; marker` and `light plain same role: added marker hands the
        # alternate back` guard that coupling. Where a marker's own code IS the role's code - `added` and
        # `32` in the dark table - the marker moves with the text, which changes nothing a reader could see.
        $parts.Add("`e[$($c.AltSgr)m$($s.Text.Replace("`e[$($c.Sgr)m", "`e[$($c.AltSgr)m"))`e[0m")
    }
    return ($parts -join $sep)
}

# Two rendered groups laid out across $Target cells: the left group packed as it always was, then
# padding, then the right group flush against the right edge. $null when the two will not fit, which is
# the caller's signal to shed something and ask again.
#
# THE PADDING IS COUNTED IN CELLS, NOT CHARACTERS, and that is the whole of this function. A rendered
# line carries an SGR colour code in front of every segment and can carry six OSC 8 hyperlink wrappers -
# the folder and branch segments each emit one in Text and another in Short, and the pr segment emits
# one - and none of that draws a single cell. A subtraction from .Length would come out short by the
# length of every escape on the line, which for a linked folder and branch is over a hundred characters,
# and the "aligned" line would be far narrower than the width it was given and would not reach the edge.
# Get-VisibleWidth is the one measurement in this script that knows what a terminal actually draws, and
# it is the one the fitting stages already measure with, so using it here also means the padding and the
# fitting cannot disagree about how wide the line is.
#
# An empty right group is the whole of the behaviour that was here before this parameter existed: the
# left line is returned exactly as it was built, with no padding at all. A config with no right group
# must not start emitting a line padded out to the full width with trailing spaces.
# The gap is at least one space, so the two groups can never touch - which in powerline style would butt
# an arrow straight into the next block. There are only two groups to keep apart when there is something
# on the left, so an empty left group asks only that the right group fits.
function Join-AlignedLine([string] $Left, [string] $Right, [int] $Target) {
    if (-not $Right) {
        if ((Get-VisibleWidth $Left) -le $Target) { return $Left }
        return $null
    }
    $pad = $Target - (Get-VisibleWidth $Left) - (Get-VisibleWidth $Right)
    $minGap = if ($Left) { 1 } else { 0 }
    if ($pad -lt $minGap) { return $null }
    return $Left + (' ' * $pad) + $Right
}

# Renders a line and, when a width is given, shrinks then drops segments until it fits.
# $Right names the segments that leave the packed line and sit flush against the right edge, in the
# order the list gives; everything else stays where it was. A name no segment on the line carries is
# skipped, so a right group naming a switched-off segment is a no-op rather than a layout change.
# Stage 1 swaps segments for their Short form in $ShrinkOrder (cost, limits, cache, context, branch,
# folder, badges, then clock by default: the cost segment's Short is the session total without its
# per-turn delta, so the delta is the first detail on the line to go; the cache segment's Short drops
# the word and keeps the countdown, which costs one word and loses nothing; and the clock's api share
# is the last). It reaches into BOTH groups: a Short form is detail shed, and which side of the line a
# segment sits on says nothing about whether that detail is worth losing.
# Stage 2 empties the right group, LAST NAMED FIRST, because a segment pushed to the edge is decoration
# and the whole group is worth less than one packed segment. A dropped right member is gone, not moved
# back into the left group: re-inlining it would make the line wider, which is the opposite of what the
# stage is for. If the gap would fall below one space the groups do not fit and the next member goes.
# Stage 3 drops whole segments from the left group in $DropOrder. Either order left $null comes from the
# registry's ranks; an empty array skips that stage. The model segment is never dropped whatever either
# order says, in the right group or the left, so it may overflow on its own.
# WHEN THE TWO GROUPS TOGETHER CANNOT FIT, that is the answer: the right group is empty before stage 3
# begins, so the case degrades exactly into the one-group fitting that was here before, and a left group
# that still will not fit overflows with the model on it the way it always has.
# Returns $null when nothing is left in either group.
# $Palette is carried rather than used: nothing in the fitting decides a colour, and every rendered
# line this function builds and measures comes out of Format-Line, so the palette has to reach all of
# them or a shrink stage would compare a light line against a dark one.
function Get-FittedLine($Segments, [string] $Style, $Width, [string[]] $ShrinkOrder = $null, [string[]] $DropOrder = $null, [string[]] $Right = $null, [string] $Palette = 'dark', [string] $Tint = 'role') {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s.Clone()) } }
    if ($segs.Count -eq 0) { return $null }
    # No width is no target to align to, so there is no right group either: every segment renders inline
    # in its ordinary place, which is what the caller with COLUMNS unset has always been given.
    if ($null -eq $Width) { return (Format-Line $segs $Style $Palette $Tint) }
    $target = [int] $Width
    $rights = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($name in $Right) {
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($segs[$i].Name -eq $name) { $rights.Add($segs[$i]); $segs.RemoveAt($i); break }
        }
    }
    $line = Join-AlignedLine (Format-Line $segs $Style $Palette $Tint) (Format-Line $rights $Style $Palette $Tint) $target
    if ($line) { return $line }
    if ($null -eq $ShrinkOrder) { $ShrinkOrder = Get-SegmentOrder 'ShrinkRank' }
    if ($null -eq $DropOrder) { $DropOrder = Get-SegmentOrder 'DropRank' }
    foreach ($name in $ShrinkOrder) {
        # Two lists rather than one, and a segment name is in exactly one of them, so the left-then-right
        # order here settles nothing: it is a search, not a precedence.
        foreach ($list in $segs, $rights) {
            for ($i = 0; $i -lt $list.Count; $i++) {
                if ($list[$i].Name -eq $name -and $list[$i].Short) {
                    $list[$i].Text = $list[$i].Short
                    $line = Join-AlignedLine (Format-Line $segs $Style $Palette $Tint) (Format-Line $rights $Style $Palette $Tint) $target
                    if ($line) { return $line }
                }
            }
        }
    }
    for ($i = $rights.Count - 1; $i -ge 0; $i--) {
        if ($rights[$i].Name -eq 'model') { continue }
        $rights.RemoveAt($i)
        if ($segs.Count + $rights.Count -eq 0) { return $null }
        $line = Join-AlignedLine (Format-Line $segs $Style $Palette $Tint) (Format-Line $rights $Style $Palette $Tint) $target
        if ($line) { return $line }
    }
    foreach ($name in $DropOrder) {
        if ($name -eq 'model') { continue }
        $at = -1
        for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i].Name -eq $name) { $at = $i } }
        if ($at -lt 0) { continue }
        $segs.RemoveAt($at)
        if ($segs.Count + $rights.Count -eq 0) { return $null }
        $line = Join-AlignedLine (Format-Line $segs $Style $Palette $Tint) (Format-Line $rights $Style $Palette $Tint) $target
        if ($line) { return $line }
    }
    # Nothing fits. The right group is empty by now unless the caller pushed the model itself to the
    # edge, which is the one member stage 2 leaves standing, so this is the over-wide line the function
    # has always returned - joined by a single space in the one case where there is still a group to
    # join, because there is no room left to align it into.
    $leftLine = Format-Line $segs $Style $Palette $Tint
    $rightLine = Format-Line $rights $Style $Palette $Tint
    if (-not $rightLine) { return $leftLine }
    if (-not $leftLine) { return $rightLine }
    return "$leftLine $rightLine"
}

# Parses `git status --porcelain=v1 --branch` output. $null when the header line is missing.
# Ahead and Behind come from the header's bracket ([ahead 1], [behind 2], [ahead 1, behind 2]); no bracket
# or [gone] means 0 and 0. Every later line starts with two status columns, XY, and is counted as
# staged (X set and not a conflict), modified (Y set: M, D, T, or A for an intent-to-add file), untracked
# (??) or a conflict (the unmerged pairs: U in either column, DD or AA). A file can be both staged and
# modified. Dirty is true when any count is above zero.
function Read-PorcelainStatus([string] $Text) {
    if (-not $Text) { return $null }
    $lines = $Text -split "`r?`n"
    if (-not $lines[0].StartsWith('## ')) { return $null }
    $head = $lines[0].Substring(3)
    $branch = if ($head -eq 'HEAD (no branch)') { 'detached' }
    elseif ($head -match '^(No commits yet|Initial commit) on (.+)$') { ($Matches[2] -split '\.\.\.', 2)[0] }
    else { ($head -split '\.\.\.', 2)[0] }
    $ahead = 0
    $behind = 0
    if ($head -match '\[(?:ahead (\d+))?(?:, )?(?:behind (\d+))?\]') {
        if ($Matches[1]) { $ahead = [int] $Matches[1] }
        if ($Matches[2]) { $behind = [int] $Matches[2] }
    }
    $staged = 0
    $modified = 0
    $untracked = 0
    $conflicts = 0
    # Porcelain v1 keeps the leading space of " M file", so the columns are read from the raw line. An
    # index loop with char tests rather than a pipeline: this runs once per entry, and a large unignored
    # tree has thousands of them.
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -lt 2 -or -not $line.Trim()) { continue }
        $x = $line[0]
        $y = $line[1]
        if ($x -eq '!') { continue }
        if ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'D' -and $y -eq 'D') -or ($x -eq 'A' -and $y -eq 'A')) { $conflicts++; continue }
        if ($x -eq '?') { $untracked++; continue }
        if ($x -ne ' ') { $staged++ }
        if ($y -ne ' ') { $modified++ }
    }
    $dirty = ($staged + $modified + $untracked + $conflicts) -gt 0
    # git permits a right-to-left override in a ref name, so the Format characters come out of the
    # branch here, at the source, rather than being left to whatever renders it.
    return @{ Branch = (Format-PayloadText $branch); Dirty = $dirty; Ahead = $ahead; Behind = $behind
              Staged = $staged; Modified = $modified; Untracked = $untracked; Conflicts = $conflicts }
}

# Runs git status in $Dir with a hard timeout. Any failure, or no git on PATH, returns $null.
# Stdout and stderr are drained on .NET threads so a long listing cannot fill the pipe and stall git.
# $WaitForExit answers "did git finish inside the budget" and defaults to the wait itself, so no caller
# passes one and every render takes the line below. It exists for the tests, the way Get-PaceArrow's
# $Now does: what happens when git does not answer - the tree is killed and the probe reports nothing -
# could otherwise only be reached by really waiting a timeout out behind a fake that really hangs, and
# a check written that way is a check on a wall clock, which a loaded machine does not honour. Given a
# script block, it is called with the process and the timeout and its answer stands in for the wait's,
# so the decision can be taken deliberately in a test and the clock left out of it.
function Get-GitBranch([string] $Dir, [int] $TimeoutMs, [scriptblock] $WaitForExit) {
    if (-not $Dir) { return $null }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $git = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { if ($script:diagOn) { Write-StatusDiag 'git probe: git is not on PATH' }; return $null }
    $p = $null
    $outTask = $null
    $errTask = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($git)
        foreach ($a in @('-C', $Dir, 'status', '--porcelain=v1', '--branch')) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Environment['GIT_OPTIONAL_LOCKS'] = '0'
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $exited = if ($WaitForExit) { [bool] (& $WaitForExit $p $TimeoutMs) } else { $p.WaitForExit($TimeoutMs) }
        if (-not $exited) {
            # Kill the whole tree, then give it a moment to actually go away before we dispose the handles.
            try { $p.Kill($true) } catch { if ($script:diagOn) { Write-StatusDiag "git probe: kill failed: $($_.Exception.Message)" } }
            [void] $p.WaitForExit(100)
        }
        # Bounded waits on both drains: the full timeout after a clean exit, so a slow reader cannot cost
        # us the branch, and a short grace after a kill, where the result is discarded anyway. A faulted
        # task is observed here rather than left to the finalizer.
        $drainMs = if ($exited) { $TimeoutMs } else { 100 }
        try { [void] [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), $drainMs) } catch { if ($script:diagOn) { Write-StatusDiag "git probe: drain failed: $($_.Exception.Message)" } }
        if (-not $exited) { if ($script:diagOn) { Write-StatusDiag "git probe: no answer within $TimeoutMs ms" }; return $null }
        if (-not $outTask.IsCompletedSuccessfully) { if ($script:diagOn) { Write-StatusDiag 'git probe: stdout did not drain' }; return $null }
        if ($p.ExitCode -ne 0) { if ($script:diagOn) { Write-StatusDiag "git probe: git exited $($p.ExitCode)" }; return $null }
        return Read-PorcelainStatus $outTask.Result
    } catch { if ($script:diagOn) { Write-StatusDiag "git probe failed: $($_.Exception.Message)" }; return $null }
    finally {
        # Disposing closes the redirected streams, so it is only safe once both drains have finished. The
        # bounded wait after a kill can return with a ReadToEndAsync still pending; disposing then would
        # pull the reader out from under it. In that case leave the handles alone - the script exits a few
        # milliseconds later and the operating system reclaims them.
        if ($p -and $outTask -and $errTask -and $outTask.IsCompleted -and $errTask.IsCompleted) { $p.Dispose() }
    }
}

# The first 16 hex characters, lower-case, of the SHA-256 of a string's UTF-8 bytes. Names the state
# file for an id that cannot name itself, and the cache entry for a repository.
function Get-ShortHash([string] $Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return [BitConverter]::ToString($digest, 0, 8).Replace('-', '').ToLowerInvariant()
}

# The cache write is in front of the line, while the state write is after it. A bounded reader may
# still hold a destination while its pool close finishes, and Windows can refuse even that reader's
# delete-sharing handle. The cache write therefore makes one immediate best-effort move: a refusal is
# swallowed by the cache caller, leaves this render without a fresh entry, and the next render re-probes
# git. It never waits or retries an HResult, because one refused move costs microseconds while waiting
# could put an unbounded filesystem close in front of the line.
function Move-AtomicFile([string] $Source, [string] $Destination) {
    [System.IO.File]::Move($Source, $Destination, $true)
}

# Writes compact UTF-8 JSON to a sibling .tmp then atomically replaces the destination exactly once.
function Write-AtomicJson([string] $Path, $Object, [int] $Depth) {
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth -Compress -ErrorAction Stop
    if (-not $json) { return $false }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    $null = Invoke-BoundedFilePendingSweep
    Move-AtomicFile $tmp $Path
    return $true
}

# ---- Git probe cache ----
# Every render is a new process, so without help each one would shell out to git status and wait for
# it. The branch segment instead keeps the last probe result per repository in a small JSON file and
# reuses it while the repository's git directory carries the same stamps and the entry is young. The
# stamps cover the files and ref directories that every commit, checkout, add, reset, merge, fetch and
# push moves; an edit or a new file in the work tree moves none of them, so those show up when the
# entry ages out. Every failure here is silent and ends in a probe.

# The work tree at or above $Dir and its git directory, as @{ WorkTree; GitDir }, neither with a
# trailing separator. The walk stops at the first .git entry that is a repository: a directory holding
# a HEAD file, or a file whose one line is `gitdir: <path>` (a worktree or a submodule), the path taken
# relative to the directory holding the file when it is not rooted. A .git directory without a HEAD is
# not a repository, and the walk carries on above it as git does, so a stray empty .git folder cannot
# key the cache on the wrong root. $null when $Dir is missing, the walk reaches the file system root, or
# a gitdir file points nowhere. The walk knows nothing of GIT_CEILING_DIRECTORIES, which is for git
# itself: a root found here is only a place to look for an entry, and an entry is only written after
# git has answered.
function Get-GitRepoRoot([string] $Dir) {
    try {
        if (-not $Dir -or -not [System.IO.Directory]::Exists($Dir)) { return $null }
        $path = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Dir))
        while ($path) {
            $dotGit = [System.IO.Path]::Combine($path, '.git')
            if ([System.IO.Directory]::Exists($dotGit)) {
                if ([System.IO.File]::Exists([System.IO.Path]::Combine($dotGit, 'HEAD'))) { return @{ WorkTree = $path; GitDir = $dotGit } }
            } elseif ([System.IO.File]::Exists($dotGit)) {
                $line = ([System.IO.File]::ReadAllText($dotGit) -split "`r?`n", 2)[0].Trim()
                if (-not $line.StartsWith('gitdir:')) { return $null }
                $gitDir = $line.Substring(7).Trim()
                if (-not $gitDir) { return $null }
                if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = [System.IO.Path]::Combine($path, $gitDir) }
                $gitDir = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($gitDir))
                if (-not [System.IO.File]::Exists([System.IO.Path]::Combine($gitDir, 'HEAD'))) { return $null }
                return @{ WorkTree = $path; GitDir = $gitDir }
            }
            $path = [System.IO.Path]::GetDirectoryName($path)
        }
        return $null
    } catch { if ($script:diagOn) { Write-StatusDiag "git cache: repository walk failed: $($_.Exception.Message)" }; return $null }
}

# The stamp string for a git directory: the UTC ticks, joined with commas, of the directory itself, of
# index, HEAD, ORIG_HEAD, FETCH_HEAD, MERGE_HEAD, packed-refs, logs/HEAD, config and info/exclude (0
# for one that is not there, as index is in a repository with no commits yet), then of refs and every
# directory below it in ordinal order. Git writes a ref as x.lock renamed into place, and a rename
# moves the parent directory's stamp, so a fetch, a push or an empty commit that touches no file above
# still shows. A worktree's git directory names its main repository's in a commondir file, and that
# directory's stamps follow after a bar, because the refs live there. One FileInfo or DirectoryInfo per
# stamp. The walk under refs stops at 256 directories: a repository with more (pull-request fetch
# refs, notes, automation refs) would pay for enumerating and sorting them on every render, so it gets
# a stamp that can never match - the ticks now behind an over-cap: marker - and Get-CachedGitBranch
# treats that as no cache at all.
function Get-GitStamp([string] $GitDir, [switch] $NoCommon) {
    $ticks = [System.Collections.Generic.List[string]]::new()
    $ticks.Add([string] [System.IO.DirectoryInfo]::new($GitDir).LastWriteTimeUtc.Ticks)
    foreach ($rel in @('index', 'HEAD', 'ORIG_HEAD', 'FETCH_HEAD', 'MERGE_HEAD', 'packed-refs', 'logs/HEAD', 'config', 'info/exclude')) {
        $fi = [System.IO.FileInfo]::new([System.IO.Path]::Combine($GitDir, $rel))
        $ticks.Add([string] $(if ($fi.Exists) { $fi.LastWriteTimeUtc.Ticks } else { 0 }))
    }
    $refs = [System.IO.Path]::Combine($GitDir, 'refs')
    if ([System.IO.Directory]::Exists($refs)) {
        $dirs = [System.Collections.Generic.List[string]]::new()
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($refs, '*', [System.IO.SearchOption]::AllDirectories)) {
            if ($dirs.Count -ge 256) { return 'over-cap:' + [DateTime]::UtcNow.Ticks }
            $dirs.Add($d)
        }
        $dirs.Sort([System.StringComparer]::Ordinal)
        $ticks.Add([string] [System.IO.DirectoryInfo]::new($refs).LastWriteTimeUtc.Ticks)
        foreach ($d in $dirs) { $ticks.Add([string] [System.IO.DirectoryInfo]::new($d).LastWriteTimeUtc.Ticks) }
    }
    $stamp = $ticks -join ','
    if ($NoCommon) { return $stamp }
    $commonFile = [System.IO.FileInfo]::new([System.IO.Path]::Combine($GitDir, 'commondir'))
    if ($commonFile.Exists) {
        $common = ([System.IO.File]::ReadAllText($commonFile.FullName) -split "`r?`n", 2)[0].Trim()
        if ($common) {
            if (-not [System.IO.Path]::IsPathRooted($common)) { $common = [System.IO.Path]::Combine($GitDir, $common) }
            $common = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($common))
            if ($common -ne $GitDir -and [System.IO.Directory]::Exists($common)) {
                $commonStamp = Get-GitStamp $common -NoCommon
                if ($commonStamp.StartsWith('over-cap:')) { return $commonStamp }
                $stamp += '|' + $commonStamp
            }
        }
    }
    return $stamp
}

# A cache entry's result as the branch record, or $null when it does not pass the guards the payload
# path applies: Branch must be text, Dirty a boolean, and each count a whole non-negative number. The
# record keeps any other key the probe may grow later, as it was stored.
function Read-CachedRecord($r) {
    if ($r -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    # Stripped again on the way out of the file. A cache entry written by this script is already clean,
    # but the file is on disk and this is the path an edited one comes back through.
    $branch = Get-PayloadText $r.Branch
    if ($null -eq $branch -or $r.Dirty -isnot [bool]) { return $null }
    $info = @{}
    foreach ($prop in $r.PSObject.Properties) { $info[$prop.Name] = $prop.Value }
    $info.Branch = $branch
    foreach ($key in @('Ahead', 'Behind', 'Staged', 'Modified', 'Untracked', 'Conflicts')) {
        $n = Get-PayloadNumber $r.$key
        if ($null -eq $n -or $n -lt 0) { return $null }
        $info[$key] = $n
    }
    return $info
}

# The cache directory: claude-statusline under TEMP, else TMPDIR, else the runtime's temp path, so the
# cache works on Linux and macOS too. TEMP is read first so a test can point the cache into its own tree.
function Get-GitCacheDir {
    $base = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [System.IO.Path]::GetTempPath() }
    return [System.IO.Path]::Combine($base, 'claude-statusline')
}

# Get-GitBranch with a cache in front of it. The entry for a repository is <hash>.json in $CacheDir,
# where the hash is Get-ShortHash of the lower-cased work tree path. It holds v (1), root (the work
# tree), stamps (Get-GitStamp of its git directory), writtenAt (Unix seconds) and result: the record
# Get-GitBranch returned with whatever keys it had, or null when it returned nothing. The entry is used
# when it parses, names the same root, carries the same stamps, and writtenAt is within $Ttl seconds of
# now either way, so a clock that went backwards reads as stale rather than as fresh for years. A null
# result is a hit too: the slow repository, and the machine with no git, pay for the probe once per
# lifetime rather than once per render. Anything else - no entry, a stale one, a corrupt one, a record
# that fails Read-CachedRecord, a read that throws - is a miss: git runs, and the answer is written
# back through Write-AtomicJson, then the directory is swept of day-old files. With no directory, a
# $Ttl of 0, no repository found, or a stamp that cannot be taken (the walk threw, or refs are over the
# cap) this is a plain probe, and nothing is written. The stamps are read before git runs, so a change
# that lands during the probe invalidates the entry. The directory is created only when there is
# something to write, and a failure to create it, or to write, costs nothing but the cache.
#
# Cache freshness is always measured against the real wall clock. A render never supplies a clock here:
# writtenAt is a filesystem fact, not a figure that is drawn. Tests pin entry ages in their fixtures
# instead of injecting a clock into this function.
function Get-CachedGitBranch([string] $Dir, [int] $TimeoutMs, [string] $CacheDir, [int] $Ttl) {
    $repo = if ($CacheDir -and $Ttl -gt 0) { Get-GitRepoRoot $Dir } else { $null }
    if (-not $repo) {
        if ($script:diagOn) {
            if ($CacheDir -and $Ttl -gt 0) { Write-StatusDiag "git cache: skipped (no repository above $Dir)" } else { Write-StatusDiag 'git cache: skipped (off in the config)' }
        }
        return Get-GitBranch $Dir $TimeoutMs
    }
    $root = $repo.WorkTree
    $stamps = $null
    try { $stamps = Get-GitStamp $repo.GitDir } catch { if ($script:diagOn) { Write-StatusDiag "git cache: stamp failed: $($_.Exception.Message)" } }
    if (-not $stamps -or $stamps.StartsWith('over-cap:')) {
        if ($script:diagOn) {
            if ($stamps) { Write-StatusDiag 'git cache: skipped (the repository is over the ref cap)' } else { Write-StatusDiag 'git cache: skipped (no stamp)' }
        }
        return Get-GitBranch $Dir $TimeoutMs
    }
    $path = [System.IO.Path]::Combine($CacheDir, (Get-ShortHash $root.ToLowerInvariant()) + '.json')
    # DELIBERATELY THE REAL CLOCK, not Get-StatusClock: this compares against writtenAt, a stamp a
    # previous render put in the file, and freshness is a fact about the filesystem rather than a figure
    # on the line. A render under CLAUDE_STATUSLINE_NOW naming another year would read every entry as
    # ancient (or as written in the future) and either re-probe git on every render or serve an entry
    # that is genuinely stale. The seam exists to pin what is DRAWN; nothing here is drawn.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        # The entry is read the way the user's own config is: one clock over the open, the length, the
        # reads and the close, on a file this process wrote itself. It is exactly the shape #48 gave the
        # config read - one existence test and one whole-file read - so it costs one bounded read rather
        # than the machinery a walk would need, and a temp directory gone slow can no longer hold the
        # line while an entry that is not there is looked for.
        $entry = Read-BoundedFileText $path -Trusted
        if ($script:diagOn) { Write-BoundedReadDiag 'cache read' }
        if ($entry) {
            $j = $entry | ConvertFrom-Json -ErrorAction Stop
            if ($j -is [System.Management.Automation.PSCustomObject] -and [long] $j.v -eq 1 -and
                $j.root -is [string] -and $j.root -eq $root -and
                $j.stamps -is [string] -and $j.stamps -ceq $stamps -and
                [math]::Abs($now - [long] $j.writtenAt) -lt $Ttl -and $null -ne $j.PSObject.Properties['result']) {
                if ($null -eq $j.result) { if ($script:diagOn) { Write-StatusDiag 'git cache: hit (the entry holds no branch)' }; return $null }
                $info = Read-CachedRecord $j.result
                if ($info) { if ($script:diagOn) { Write-StatusDiag "git cache: hit ($($info.Branch))" }; return $info }
                if ($script:diagOn) { Write-StatusDiag 'git cache: miss (the record did not pass the guards)' }
            } else {
                if ($script:diagOn) { Write-StatusDiag 'git cache: miss (the entry is stale or does not match)' }
            }
        } else {
            # Nothing came back. Almost always that is the first render for a repository; anything else -
            # over the cap, past the deadline - has already named itself on the line above.
            if ($script:diagOn) { Write-StatusDiag 'git cache: miss (no entry yet)' }
        }
    } catch { if ($script:diagOn) { Write-StatusDiag "git cache: read failed: $($_.Exception.Message)" } }
    $info = Get-GitBranch $Dir $TimeoutMs
    try {
        [void] [System.IO.Directory]::CreateDirectory($CacheDir)
        if (Write-AtomicJson $path ([ordered]@{ v = 1; root = $root; stamps = $stamps; writtenAt = $now; result = $info }) 3) { Invoke-SessionStateSweep $CacheDir }
    } catch { if ($script:diagOn) { Write-StatusDiag "git cache: write failed: $($_.Exception.Message)" } }
    return $info
}

# A payload or state field as a finite double, or $null when it is not a number at all: missing, a
# boolean, a string, an array, NaN or infinite. This is the one guard behind Get-PayloadNumber and
# Get-StateNumber, each of which then applies its own rule to the result - a count that fits an Int32,
# or a figure floored to a long. It sits here because the script runs top to bottom and both callers
# are below.
function Get-FiniteNumber($v) {
    if (-not ($v -is [ValueType]) -or $v -is [bool]) { return $null }
    $n = try { [double] $v } catch { return $null }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    return $n
}

# ---- Per-session state ----
# Each render is a fresh process that sees one payload, so a small JSON file per session keeps the last
# cost, token totals and a short cost history for the next render to compare against. The cost segment's
# per-turn delta reads it, so the read happens before the segments are built; the merge and the write
# still happen after the line is printed. Every failure here is silent: no directory, no file, no state,
# and the line is what it would have been with no previous render at all.

# The state directory: claude-statusline-state under TEMP, or ~/.claude/statusline-state when TEMP is
# empty. Created only when $Create is set, which the write path does. $null when it is not there and
# cannot be made, including when a file sits at its path.
function Get-SessionStateDir([bool] $Create) {
    try {
        $dir = if ($env:TEMP) { Join-Path $env:TEMP 'claude-statusline-state' } else { Join-Path $HOME '.claude' 'statusline-state' }
        if (-not [System.IO.Directory]::Exists($dir)) {
            if (-not $Create) { return $null }
            [void] [System.IO.Directory]::CreateDirectory($dir)
        }
        return $dir
    } catch { if ($script:diagOn) { Write-StatusDiag "state dir failed: $($_.Exception.Message)" }; return $null }
}

# The file for a session, <name>.json. When the id is already lower-case, at most 64 characters and has
# nothing outside [A-Za-z0-9_.-] (a UUID), the id is the name. Any other id would not name itself
# uniquely: stripping or cutting gives two ids one file (`a/b` and `ab`, or two long ids with the same
# first 64 characters), and so does case alone, because the file system folds it (`A1` and `a1`). Such
# an id gets the lower-cased readable part, cut to 47 characters, a hyphen, and the first 16 hex
# characters of the SHA-256 of the whole original id; the hash alone when nothing readable is left.
# Slashes are never kept, so an id cannot name a path outside the directory. $null for an empty id or
# when there is no directory.
function Get-SessionStatePath([string] $SessionId, [bool] $Create) {
    if (-not $SessionId) { return $null }
    $name = [regex]::Replace($SessionId, '[^A-Za-z0-9_.-]', '')
    if ($name -cne $SessionId.ToLowerInvariant() -or $name.Length -gt 64) {
        $hash = Get-ShortHash $SessionId
        $prefix = $name.ToLowerInvariant()
        if ($prefix.Length -gt 47) { $prefix = $prefix.Substring(0, 47) }
        $name = if ($prefix) { "$prefix-$hash" } else { $hash }
    }
    $dir = Get-SessionStateDir $Create
    if (-not $dir) { return $null }
    return Join-Path $dir "$name.json"
}

# A payload or state value as a figure, or $null when Get-FiniteNumber says it is not a number.
# With -Whole the result is floored to a long, and $null when it would not fit one.
function Get-StateNumber($v, [switch] $Whole) {
    $n = Get-FiniteNumber $v
    if ($null -eq $n) { return $null }
    if (-not $Whole) { return $n }
    if ([math]::Abs($n) -gt 9e15) { return $null }
    return [long] [math]::Floor($n)
}

# A cumulative figure: a running total that only ever counts up, which is what the dollars spent and the
# token counts are. Get-StateNumber first, then the sign, because finite is not the same question as
# possible - no session has ever spent minus a hundred dollars or sent minus four thousand tokens, so a
# negative here is evidence that a payload or a hand-edited file is wrong rather than a figure to keep.
# It is refused exactly the way a string or a boolean already is: the figure becomes $null and every
# reader treats it as a figure that is not there. That is deliberately not a clamp to zero. A clamp
# would turn an impossible input into the most reassuring possible output - a delta measured from a
# baseline of nothing - where a refusal makes the absence visible instead.
# The refusal is per field, not per record, which is the rule the rest of this file already follows: a
# figure of any other shape nulls itself and leaves the record's other keys alone, and a whole record is
# thrown away only for a structural fault - not JSON, or not version 1. One corrupt counter is no
# evidence about the ring or about the other counters, and discarding those would cost more deltas than
# it saves. Every field that goes missing here fails safe: the segment renders without its delta, which
# is the same path as a session that has no state file at all.
# The two percentages do not come through here. They are gauges rather than counters, and their range is
# not this function's to decide: a rate limit really can report over 100, and the one reader a stored
# percentage has - the pace arrow's fallback - already refuses anything at or below zero at its own door.
function Get-CountedNumber($v, [switch] $Whole) {
    $n = Get-StateNumber $v -Whole:$Whole
    if ($null -eq $n -or $n -lt 0) { return $null }
    return $n
}

# The state last written for a session, as a hashtable with the schema's keys, or $null for no file,
# unreadable JSON, or a version other than 1. Each figure is a number or $null; history entries without
# both a time and a cost are dropped. The three counters and the ring's costs go through
# Get-CountedNumber, so a negative one - which no session can reach, and which a hand-edited file can
# hold - reads as a figure that is not there rather than as a baseline to measure a delta from.
function Read-SessionState([string] $SessionId) {
    try {
        $path = Get-SessionStatePath $SessionId $false
        if (-not $path) { if ($script:diagOn) { Write-StatusDiag 'state: no file yet' }; return $null }
        # Bounded, for the same reason and in the same shape as the cache entry above: one existence
        # test and one whole-file read of a file this process wrote, on the render's own thread, before
        # the segments are built. The write at the foot of the script is after the line is printed and
        # stays as it was.
        $text = Read-BoundedFileText $path -Trusted
        if ($script:diagOn) { Write-BoundedReadDiag 'state read' }
        if (-not $text) { if ($script:diagOn) { Write-StatusDiag 'state: no file yet' }; return $null }
        $j = $text | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject] -or (Get-StateNumber $j.v) -ne 1) { if ($script:diagOn) { Write-StatusDiag 'state: the file is not a version 1 record' }; return $null }
        $history = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($h in @($j.history)) {
            $t = Get-StateNumber $h.t -Whole
            $c = Get-CountedNumber $h.cost_usd
            if ($null -ne $t -and $null -ne $c) { $history.Add(@{ t = $t; cost_usd = $c }) }
        }
        $state = @{ v = 1; history = @($history) }
        # updated_at is a clock reading rather than a counter, so it keeps the plain rule.
        $state['updated_at'] = Get-StateNumber $j.updated_at -Whole
        foreach ($key in @('input_tokens', 'output_tokens')) { $state[$key] = Get-CountedNumber $j.$key -Whole }
        $state['cost_usd'] = Get-CountedNumber $j.cost_usd
        foreach ($key in @('used_percentage', 'five_hour_percentage')) { $state[$key] = Get-StateNumber $j.$key }
        if ($script:diagOn) { Write-StatusDiag "state: read ($path)" }
        return $state
    } catch { if ($script:diagOn) { Write-StatusDiag "state read failed: $($_.Exception.Message)" }; return $null }
}

# The next state for a session: the payload's figures now, the counters the payload did not carry kept
# from the previous state (see the block above the record), and the history ring carried over with a
# new entry when the cost moved (a first render counts as moved). The ring keeps the newest 20. Keys
# are in schema order so the file always reads the same way.
# The comparison is against the last entry in the ring, not against the record's cost_usd: the ring
# holds only figures a payload actually carried, so it is the honest answer to "has the cost moved
# since it was last seen", while cost_usd may be one carried forward across a payload that had none.
# A payload can arrive with no cost object at all - the minimal sample is that shape - and comparing
# against a carried figure would be comparing against a reading that never happened.
function Merge-SessionState($Previous, $Payload, [long] $Now) {
    $cost = Get-CountedNumber $Payload.cost.total_cost_usd
    $history = [System.Collections.Generic.List[hashtable]]::new()
    if ($Previous) {
        foreach ($h in @($Previous.history)) { if ($h) { $history.Add($h) } }
    }
    $last = if ($history.Count -gt 0) { Get-StateNumber $history[$history.Count - 1].cost_usd } else { $null }
    if ($null -ne $cost -and $cost -ne $last) { $history.Add(@{ t = $Now; cost_usd = $cost }) }
    while ($history.Count -gt 20) { $history.RemoveAt(0) }
    $ctx = $Payload.context_window
    # A payload that does not carry a figure is not a session that lost it, so the three counters keep
    # what the record holds rather than being overwritten with nothing. They count up over a session -
    # dollars spent, tokens in, tokens out - and the next render measures its delta from them, so one
    # payload without a cost object would otherwise erase the total a rise is measured against and that
    # rise would never be shown on any line. This is the rule the history ring above already follows;
    # the two disagreed until now. A figure that is present but is not a number is a figure the payload
    # did not carry and carries the same way, while a real zero is a figure and replaces the one before.
    # The two percentages are gauges, not counters: how full the window is now, how much of this
    # five-hour window has gone. A carried-forward gauge is worse than none, because a compaction, a
    # fresh window or a changed model makes the old figure a confident lie about the present, and the
    # five-hour figure drops to zero at its own boundary, so a stale one reads as usage that has not
    # happened. Both are read fresh every render and are simply absent when the payload is silent -
    # which is what the pace arrow's optional fallback wants, since no figure is a fallback it can
    # decline and a wrong one is not.
    return [ordered]@{
        v = 1
        updated_at = $Now
        cost_usd = $cost ?? (Get-CountedNumber $Previous.cost_usd)
        input_tokens = (Get-CountedNumber $ctx.total_input_tokens -Whole) ?? (Get-CountedNumber $Previous.input_tokens -Whole)
        output_tokens = (Get-CountedNumber $ctx.total_output_tokens -Whole) ?? (Get-CountedNumber $Previous.output_tokens -Whole)
        used_percentage = Get-StateNumber $ctx.used_percentage
        five_hour_percentage = Get-StateNumber $Payload.rate_limits.five_hour.used_percentage
        history = @($history)
    }
}

# Housekeeping for a directory of JSON files - the state files, and the git cache entries - at most
# once per six hours per directory: a .sweep stamp marks the last finished pass. When it is missing or
# older than six hours, .json files not written for a day, and .tmp files an interrupted write left
# behind, are deleted, at most 200 in one pass. A pass that hits the cap leaves the stamp alone, so the
# next render carries on with the backlog instead of draining 200 files every six hours. Ages are
# absolute, so a stamp or a file dated in the future - a clock change, a restored backup - reads as
# stale rather than as freshly written, which would park housekeeping until the wall clock caught up.
# The common render pays for one stat of the stamp and nothing else.
function Invoke-SessionStateSweep([string] $Dir) {
    try {
        $stamp = Join-Path $Dir '.sweep'
        # DELIBERATELY THE REAL CLOCK, and here it is a safety rule rather than a preference. Every
        # comparison below is against a file's last-write time, and this function DELETES what it finds
        # old. Reading Get-StatusClock instead would mean a render under CLAUDE_STATUSLINE_NOW naming a
        # date far enough ahead sweeps away live state files that were written seconds earlier. The
        # seam pins figures on the line; it must never reach anything that removes a file.
        $now = [DateTime]::UtcNow
        if ([System.IO.File]::Exists($stamp) -and [math]::Abs(($now - [System.IO.File]::GetLastWriteTimeUtc($stamp)).TotalHours) -lt 6) { return }
        $deleted = 0
        $capped = $false
        foreach ($pattern in @('*.json', '*.tmp')) {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($Dir, $pattern)) {
                if ($deleted -ge 200) { $capped = $true; break }
                if ([math]::Abs(($now - [System.IO.File]::GetLastWriteTimeUtc($f)).TotalDays) -lt 1) { continue }
                try { [System.IO.File]::Delete($f); $deleted++ } catch { if ($script:diagOn) { Write-StatusDiag "sweep: delete failed: $($_.Exception.Message)" } }
            }
            if ($capped) { break }
        }
        if (-not $capped) { [System.IO.File]::WriteAllText($stamp, '') }
    } catch { if ($script:diagOn) { Write-StatusDiag "sweep failed: $($_.Exception.Message)" } }
}

# Writes a session's state through Write-AtomicJson, then runs the sweep. Nothing is written for an
# empty record, an id that leaves no file name, or JSON that would not serialise - a half-written or
# empty file would cost the whole ring rather than one delta, which is why the write is atomic. Every
# failure is swallowed: the line has already been printed. Concurrent renders of one session still
# race, and the last writer wins; a lock file is out of scope for the same reason, the cost of losing
# is one missing delta.
function Write-SessionState([string] $SessionId, $State) {
    try {
        if (-not $State) { if ($script:diagOn) { Write-StatusDiag 'state: not written (nothing to write)' }; return }
        $path = Get-SessionStatePath $SessionId $true
        if (-not $path) { if ($script:diagOn) { Write-StatusDiag 'state: not written (the session id leaves no file name)' }; return }
        if (Write-AtomicJson $path $State 4) {
            if ($script:diagOn) { Write-StatusDiag "state: written ($path)" }
            Invoke-SessionStateSweep (Split-Path $path -Parent)
        } else {
            if ($script:diagOn) { Write-StatusDiag 'state: not written (the record serialised to nothing)' }
        }
    } catch { if ($script:diagOn) { Write-StatusDiag "state write failed: $($_.Exception.Message)" } }
}

$raw = Read-StdinText
$payloadOk = $true
$d = $null
try { $d = $raw | ConvertFrom-Json } catch { $payloadOk = $false }

# The config is read after the payload, because the payload names the project directory whose
# .claude\statusline.json is merged over the user file, and still before anything is printed. -Config
# replaces the user file and leaves the project file unread: it is the explicit override the tests and
# the screenshot script use, and both need a render that no directory a sample payload names can change.
$configPath = if ($Config) { Resolve-ConfigPath $Config } else { Join-Path $PSScriptRoot 'statusline.json' }
if ($script:diagOn -and $Config -and -not $configPath) { Write-StatusDiag "config path: -Config $Config is not a filesystem path; the built-in defaults stand" }
$projectDir = if ($Config) { $null } else { $d.workspace.project_dir }
$cfg = Read-StatusConfig $configPath $projectDir

# The glyphs the builders and the fallback line use, with the config's icons overrides applied - or the
# ascii table, which takes no overrides. Get-IconSet is the one place the style is read for them.
$icons = Get-IconSet $cfg
$iconModel = $icons.model
$iconCtx = $icons.context
$iconCache = $icons.cache
$iconCost = $icons.cost
$iconClock = $icons.clock
$iconTime = $icons.time
$iconFolder = $icons.folder
$iconChevron = $icons.chevron
$iconBranch = $icons.branch
$iconWorktree = $icons.worktree
$iconHome = $icons.home
$iconDirty = $icons.dirty
$iconAhead = $icons.ahead
$iconBehind = $icons.behind
$iconConflict = $icons.conflict
$iconPr = $icons.pr
$iconLines = $icons.lines
$iconLimit = $icons.limits
$iconFast = $icons.fast
$iconThink = $icons.think
$iconEffort = $icons.effort
$iconVim = $icons.vim
$iconAgent = $icons.agent
$iconSession = $icons.session

# The style's non-icon characters reach their builders as an argument, Get-MarkSet $cfg.Style, except
# this one. Get-ClippedText reads the tail it puts on a name it cut from this script variable, and that
# function is copied verbatim into subagent-statusline.ps1 with test.ps1 comparing the two as text, so
# it cannot grow a parameter for the ascii style without dragging the panel script along with it.
# Reassigning what it reads is how the style reaches it. The default above stands until here, and
# nothing between the two clips anything: the first call is inside a builder.
$ellipsis = (Get-MarkSet $cfg.Style).Ellipsis

# The names on each printed line: the config's order for layout one, the two rows for layout two. Settled
# here, above the first thing that prints, because three readers need it - both fallback lines and the
# build loop - and it depends on nothing but the config.
$lineSets = @(if ($cfg.Layout -eq 'two') { $cfg.Rows } else { , $cfg.Order })
$listed = @{}
foreach ($names in $lineSets) { foreach ($n in $names) { $listed[$n] = $true } }

# Both fallback lines print the model glyph and the word claude, which makes each of them the model
# segment with no name to put in it. Neither is printed unless the config would have allowed a model
# segment: toggled on, and named by the order or by one of the rows. One rule, decided once, so the two
# lines cannot drift apart or answer the same config differently.
$modelWanted = [bool] ($cfg.Segments['model'] -and $listed['model'])

# ---- Segment builders. Each returns $null (segment omitted) or @{ Name; Text; Short; Role; Bold }. ----

# Colour bands for a percentage. Every caller passes both bands: the config's thresholds, 60 and 85 unless
# statusline.json moves them, which suit a 200k window, or the fixed 70 and 90 of a 1M window, because 85%
# of 1M still leaves 150k tokens, more than a whole fresh 200k session, so the config does not reach them.
# No defaults here: a caller that forgot the config would bind 0 and 0 and colour everything red.
function Get-ThresholdRole([int] $pct, [int] $Warn, [int] $Bad) { if ($pct -ge $Bad) { 'bad' } elseif ($pct -ge $Warn) { 'warn' } else { 'ok' } }

# The one percentage a payload figure turns into: the whole number that goes on the line, that the
# threshold bands are read against, and that an alarm is compared with. One function for all three so
# two segments can never disagree about whether 90% has been reached - the context meter printing a red
# 90% while the model stays cyan because it looked at 89.6 is the kind of contradiction this rules out.
# The rule is round half to even (89.5 and 90.5 both give 90, 91.5 gives 92), stated here rather than
# left implicit: it is what an [int] cast of a double and a bare [math]::Round have always done in this
# script, so writing it down changes no figure that has ever been printed - it just gives the rule a
# name and one home. A number too large for an Int32 is pinned to its ends rather than throwing, so a
# payload's absurd figure ends as a clamped percentage instead of a broken render; every caller then
# applies its own range rule, and only the context meter clamps to 0..100, because a rate limit that
# really is at 105% should say so.
function Get-WholePercent([double] $n) {
    $r = [math]::Round($n, [System.MidpointRounding]::ToEven)
    if ($r -ge [int]::MaxValue) { return [int]::MaxValue }
    if ($r -le [int]::MinValue) { return [int]::MinValue }
    return [int] $r
}

# A payload percentage as a whole number, or $null when it is not a number at all - the two-step every
# percentage in the script needs, folded into one call so it cannot be reached with only the second
# step. Get-WholePercent's own parameter is typed [double], which reads like a guard but is not one:
# handed a string or a boolean, PowerShell's parameter binding fails, and under this script's
# $ErrorActionPreference of SilentlyContinue that failure is not an error the caller sees, it is a
# statement that quietly does nothing - the variable being assigned keeps whatever it already held
# rather than becoming $null. A used_percentage of "abc" then survives as the literal string "abc" and
# prints "abc%"; a used_percentage of $true survives the same way as a boolean, and since a boolean
# does satisfy [double]'s conversion (as 1 or 0) it reaches Get-WholePercent and prints "1%" - a figure
# Test-AlarmState disagrees about, because it reads the same field through Get-FiniteNumber first and
# calls a boolean no percentage at all. (Code review, following up the #45/#44 batch's own note that
# Get-ContextSegment has the identical unguarded shape: Get-CostSegment and Get-LinesSegment turned out
# to have it too, on total_cost_usd and the two line counts, none of them percentages, which is why
# those two call Get-FiniteNumber directly instead of through this wrapper.)
function Get-PayloadPercent($v) {
    $n = Get-FiniteNumber $v
    if ($null -eq $n) { return $null }
    return Get-WholePercent $n
}

# The one window size that gets the 1M marker and the wider bands. Claude Code reports it as exactly 1000000.
function Test-WideWindow($size) { return $size -eq 1000000 }

# One percentage against one alarm level: $true only when the level is above 0 and the value is at or
# above it. Both sides go through Get-WholePercent first, so the alarm compares the same whole number
# the segments print: at 89.6 the context meter shows 90% and the alarm fires, rather than the meter
# reading red 90% beside a model that thinks it is still under the line. Both arguments come straight
# from the payload and the config and are untyped, so every way of saying "no alarm here" ends in $false
# rather than an error: a level of 0 or below (that alarm is off), a missing level, a used_percentage
# that is null because the first API response has not landed, or a value of any other shape.
function Test-AlarmLevel($Value, $Level) {
    $at = Get-FiniteNumber $Level
    if ($null -eq $at) { return $false }
    $at = Get-WholePercent $at
    if ($at -le 0) { return $false }
    $pct = Get-FiniteNumber $Value
    if ($null -eq $pct) { return $false }
    return ((Get-WholePercent $pct) -ge $at)
}

# Whether this payload is in an alarm state: the context window at or above alarm.context, or either
# rate limit at or above alarm.limits. It reads the payload and the config directly rather than any
# segment record, so it does not depend on segment order, on the fitting, or on whether the context and
# limits segments are enabled at all - the model segment, which is never dropped, is what carries it,
# and a later caller (the taskbar progress of #24) can ask the same question for its own purpose.
# The spend limit is not an alarm: it is a billing ceiling rather than a rate that stops the session.
# A config with no Alarm table, and a payload with no rate_limits (absent until the first API response,
# and only on Pro and Max), are both simply no alarm.
function Test-AlarmState($d, $cfg) {
    $alarm = $cfg.Alarm
    if ($null -eq $alarm) { return $false }
    if (Test-AlarmLevel $d.context_window.used_percentage $alarm.Context) { return $true }
    $rl = $d.rate_limits
    if (Test-AlarmLevel $rl.five_hour.used_percentage $alarm.Limits) { return $true }
    return (Test-AlarmLevel $rl.seven_day.used_percentage $alarm.Limits)
}

# The taskbar progress sequence for this render, or '' when the key is off: ESC ] 9 ; 4 ; state ;
# percent BEL. Windows Terminal draws it on the window's taskbar button, so how full the context window
# is stays readable with the window minimised. Not a segment builder despite the neighbourhood - it
# reads the payload and the config the way Test-AlarmState above does, and returns a string that never
# reaches a line, is never measured and is never fitted.
#
# States: 1 normal, 2 error, 0 clear. 3, indeterminate, is never used - a status line always knows its
# number. Which of 1 and 2 is Test-AlarmState's answer and nothing narrower, so the bar turns red at
# exactly the moment the model segment does and the two can never contradict each other. That includes
# a rate limit at its level over a quiet context window: the colour says "something is at its alarm",
# and the number beside it is, and only ever is, the context window's.
#
# WHY A MISSING PERCENTAGE WRITES A CLEAR RATHER THAN NOTHING. This sequence is terminal state that
# outlives the process: whatever the last render set stays on the taskbar until something sets it
# again. A render that knows no percentage - no context_window yet, a used_percentage still null before
# the first API response, a payload that would not parse at all - and wrote nothing would leave a bar
# frozen at a figure from a session that has since moved on. The clear form costs one sequence and is
# always honest. A real 0% is a different thing and gets state 1: a known zero and an unknown figure
# must not look the same on the taskbar.
#
# The percentage is Get-WholePercent's, the one rounding rule behind the meter's text, the colour bands
# and the alarms, so the bar shows the number the line shows. It is then clamped to 0..100, the range
# the taskbar takes and the same clamp the context meter applies: a rate limit is allowed to read past
# 100 but this bar is the context window's alone.
#
# The key is tested for a real boolean and not just for truth, the way every other value that came from
# a config file is: a bare -not would read the string "false" as on, because PowerShell calls every
# non-empty string true. Read-StatusConfig only ever puts a boolean there, so this is the guard for a
# caller that hands over a table of its own.
function Get-TaskbarSequence($d, $cfg) {
    if ($cfg.Taskbar -isnot [bool] -or -not $cfg.Taskbar) { return '' }
    $pct = Get-FiniteNumber $d.context_window.used_percentage
    if ($null -eq $pct) { return "`e]9;4;0;0`a" }
    $whole = [math]::Max(0, [math]::Min(100, (Get-WholePercent $pct)))
    $state = if (Test-AlarmState $d $cfg) { 2 } else { 1 }
    return "`e]9;4;$state;$whole`a"
}

# Thousands of tokens: 1.5k, 64k, 1.0M
function K([double] $n) { if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1000000) } elseif ($n -ge 10000) { '{0:N0}k' -f ($n / 1000) } else { '{0:N1}k' -f ($n / 1000) } }

# A 1M window gets a dim "1M" after the name, so a percentage in the context segment reads against the
# right total. Once the session has passed 200k tokens the warning glyph follows it.
# The role is the alarm's: red instead of cyan once the context window or a rate limit passes the alarm
# level, with the text left exactly as it was. It is decided here rather than by the build loop because
# the "1M" marker goes through Format-Inline, which hands the segment's own foreground back after the
# muted run - a role changed after the text was built would leave that marker restoring cyan on a red
# segment. The segment is never dropped and has no short form, which is what makes it the carrier.
# model.display_name is payload text, so it goes through the same pair every other name in this script
# does: Test-PayloadText decides whether there is anything there at all - found while auditing #61,
# where vim.mode and effort.level had been left out of the same pair in the badges builder - and
# Format-PayloadText strips the format characters out of what is left, so a right-to-left override or a
# zero-width joiner in a model name cannot reorder or hide the rest of the line it leads.
# An unusable name - absent, blank, a control character, a number, an object - falls back to the same
# "claude" word the zero-segment stand-in below prints, rather than omitting the segment: this is the
# one segment the loop above never drops, because the alarm rides on it, and dropping it for a bad name
# would have let one payload field silence the alarm on a render where the context or limits segment
# still gets through (the zero-segment stand-in below only fires when EVERY segment is empty, which a
# real context or limits figure alongside a bad model name does not give it). So the segment is built
# here whatever the name is, and the stand-in below is left to cover the one case that is actually
# outside this function: model turned off, or left out of the order, where this builder is never
# called at all. (Finding from code review on #61's own fix: the first cut here returned $null for an
# absent name too, on the theory that the zero-segment stand-in would cover it - it does not, at least
# not reliably, since that stand-in is keyed on every segment being empty rather than on model
# specifically, and there is no reason to route a plain "no name" payload through a different, less
# direct path than a hostile one takes.)
function Get-ModelSegment($d, $cfg) {
    $model = (Get-PayloadText $d.model.display_name) ?? 'claude'
    $role = if (Test-AlarmState $d $cfg) { 'bad' } else { 'model' }
    $text = Format-Icon $iconModel $model
    if (Test-WideWindow $d.context_window.context_window_size) { $text += ' ' + (Format-Inline 'muted' '1M' $role $cfg.Style $cfg.Palette 'model' $cfg.Tint) }
    if ($d.exceeds_200k_tokens -is [bool] -and $d.exceeds_200k_tokens) { $text += " $iconConflict" }
    return @{ Name = 'model'; Text = $text; Short = $null; Role = $role; Bold = $true }
}

# THE RULE THIS FEATURE RESTS ON: quiet never hides a segment that is carrying a warning, an error or
# an alarm. It is a setting for hiding boring numbers, and one that also hid the alarm would be worse
# than not having it at all, so every caller checks its own warning state before it asks this question -
# the context and limits builders keep a segment whose role is warn or bad, limits keeps one whose pace
# arrow projects an overrun, and both keep one whose figure is at or above its Test-AlarmLevel line,
# whatever the threshold says. That last one is not implied by the first: alarm.context and alarm.limits
# are allowed to sit below thresholds.warn, and there the role reads ok while the model segment is red.
# The cost segment has no warning state of its own to preserve: its role is always dim, it has no
# thresholds and no alarm is read against a dollar figure, so the guard is the whole story there.
#
# True when a segment has nothing worth saying yet: the value it would show is below the config's quiet
# threshold for it, so the builder returns $null and the segment never reaches the line. The comparison
# is strict, which is what makes the default of 0 mean off - a value of 0 is not below 0. Everything is
# read defensively, untyped: a caller with no Quiet table, a name the table does not carry, and a value
# that is not a number all answer false, because a guard that cannot read its threshold must not hide a
# segment. Get-FiniteNumber is the one numeric test, so a bool or a string never counts as a figure.
function Test-QuietValue($cfg, [string] $Name, $Value) {
    $min = if ($cfg.Quiet -is [hashtable]) { Get-FiniteNumber $cfg.Quiet[$Name] } else { $null }
    $n = Get-FiniteNumber $Value
    if ($null -eq $min -or $null -eq $n) { return $false }
    return $n -lt $min
}

# How much of this turn's input the prompt cache served, as a whole percentage, or $null when there is
# nothing to report. The three counts are context_window.current_usage.{input_tokens,
# cache_creation_input_tokens, cache_read_input_tokens}: input sent fresh, input written into the cache,
# and input read back out of it. The three together are the whole input, so the read is the share of it
# that cost almost nothing, and a number that falls after an edit to a large file is the cache being
# invalidated - the usual reason a small turn suddenly costs several cents.
# The whole block is absent on older Claude Code versions and before the first API response, and every
# field goes through Get-FiniteNumber, so a missing block, a missing field, and a field carrying text, a
# bool or an array all count as 0 rather than throwing.
# THE ONE RULE THAT MAKES THIS FIGURE HONEST: a count that is negative is not a count, and a payload
# carrying one is refused outright rather than repaired. Three counts of tokens cannot be negative, so
# a negative one says the block cannot be trusted, and every way of salvaging a number from it invents
# a claim the payload does not support - most sharply an input_tokens of -100 beside a read of 200,
# which is a raw 200% and reads on the line as a confident "100% cached", a perfect cache hit
# manufactured out of a malformed block. Refusing is the same answer this function already gives for a
# current_usage that is absent, and it is the honest one: not "everything was cached" but "we cannot
# tell". A total of 0 or less is refused for the same reason, and because PowerShell throws on a
# division by zero between doubles as readily as between integers.
# There is no clamp on the result. With all three counts non-negative and a positive total, the read
# is one of the terms of its own denominator, so the ratio is between 0 and 1 - but only if the scale
# happens after the division. Written as 100 * $read / $total, a read above about 1.8e306 overflows
# the multiply to Infinity before the divide ever runs, and Get-WholePercent's Int32 guard then prints
# 2147483647% cached. Dividing first cannot overflow, because the ratio is at most 1. An earlier
# version had it the other way round and claimed in this comment to be in range by arithmetic; it was
# not, and nothing tested the range.
# A clamp was here too and it is what hid the 200% case above, turning a payload this function should
# have refused into the most reassuring number on the line - so whoever relaxes the refusal above has
# to put a clamp back, and should ask first why the payload is being trusted at all.
# The rounding is Get-WholePercent, the script's one percentage rule, and not a rule of its own. This
# figure is printed as a whole percentage beside another whole percentage built by the same function,
# and two rounding rules on one segment is exactly the disagreement that function exists to rule out.
# The choice is deliberate rather than a reflex: subagent-statusline.ps1 floors its derived percentage,
# and the case for flooring there is that the figure feeds a colour band, where overstating is what
# matters. Nothing bands or alarms on this one, so the nearest whole number is simply the truest one to
# print.
function Get-CacheShare($usage) {
    $read = (Get-FiniteNumber $usage.cache_read_input_tokens) ?? 0
    $fresh = (Get-FiniteNumber $usage.input_tokens) ?? 0
    $written = (Get-FiniteNumber $usage.cache_creation_input_tokens) ?? 0
    if ($read -lt 0 -or $fresh -lt 0 -or $written -lt 0) { return $null }
    $total = $read + $fresh + $written
    if ($total -le 0) { return $null }
    return Get-WholePercent (($read / $total) * 100)
}

function Get-ContextSegment($d, $cfg) {
    # Get-PayloadPercent is Get-FiniteNumber and Get-WholePercent together (code review: a null check
    # plus a bare Get-WholePercent call, typed [double], reads like a guard but is not one under this
    # script's SilentlyContinue - a string used_percentage would survive as that literal string and
    # print "abc%", and a boolean would survive as 1 or 0 and print a figure Test-AlarmState, which
    # reads the same field through Get-FiniteNumber below, disagrees is a percentage at all). The 0..100
    # clamp is this segment's own: the bar has ten blocks.
    $pct = Get-PayloadPercent $d.context_window.used_percentage
    if ($null -eq $pct) { return $null }
    $pct = [math]::Max(0, [math]::Min(100, $pct))
    $size = $d.context_window.context_window_size
    # ORDER MATTERS, and these three lines are why. $pct is normalised first - by Get-WholePercent,
    # which is the same rule the model segment's alarm compares against - the role is read from the
    # normalised $pct, and only then is the quiet guard asked, with the role and the alarm both settled
    # in front of it. Whoever changes how $pct is normalised must keep the role below it: a role read
    # from the raw payload figure would band the wrong number, and the guard would then hide a meter the
    # wrong colour says is calm. Both rules break at once, and a third with them: the alarm would then
    # fire on a percentage this segment never printed.
    $role = if (Test-WideWindow $size) { Get-ThresholdRole $pct 70 90 } else { Get-ThresholdRole $pct $cfg.Thresholds.Warn $cfg.Thresholds.Bad }
    # quiet.context compares the clamped percentage, which is what the segment would show. The role is
    # settled first so the rule above can hold: a meter already yellow or red is an alarm, and a
    # threshold set above the warn band must not swallow it. The model segment's own alarm is the third
    # thing weighed here, and the most serious of the three: alarm.context is allowed to sit below
    # thresholds.warn, and there the role still reads 'ok' while the model turns red - a red bar with no
    # meter under it saying which number it is about. What that test reads is the RAW payload figure and
    # not the clamped $pct, so it asks exactly the question Test-AlarmState asks for the model segment
    # and the two can never disagree, a payload above 100 against a level above 100 included.
    # Test-AlarmLevel answers false for a level that is missing, so a config with no Alarm table hides
    # what it always hid.
    if ($role -eq 'ok' -and -not (Test-AlarmLevel $d.context_window.used_percentage $cfg.Alarm.Context) -and (Test-QuietValue $cfg 'context' $pct)) { return $null }
    $filled = [math]::Round($pct / 10)
    $mark = Get-MarkSet $cfg.Style
    $bar = ($mark.BarFull * $filled) + ($mark.BarEmpty * (10 - $filled))
    # The same [double]-cast hazard as used_percentage above, found while fixing that one: a bare
    # [double] cast is not a function parameter, but it fails exactly the same way under
    # SilentlyContinue, so a hostile total_input_tokens or total_output_tokens is guarded the same way.
    $used = ((Get-FiniteNumber $d.context_window.total_input_tokens) ?? 0) + ((Get-FiniteNumber $d.context_window.total_output_tokens) ?? 0)
    $counts = if ($used -gt 0 -and $size) { " $(K $used)/$(K $size)" } elseif ($used -gt 0) { " $(K $used)" } else { '' }
    # The cached share hangs off the counts, and both live in Text alone. Short is what stage 1 of the
    # fitting swaps in, so leaving them out of it sheds the counts and the suffix together and keeps the
    # percentage and the bar on a narrow line. It is built last, after the role is settled, because
    # Format-Inline hands the segment's own foreground back after the dim run: a role decided later
    # would leave the suffix restoring an ok green on a segment the meter has since turned red.
    $share = Get-CacheShare $d.context_window.current_usage
    $tail = $counts + $(if ($null -ne $share) { ' ' + (Format-Inline 'cached' "$share% cached" $role $cfg.Style $cfg.Palette 'context' $cfg.Tint) } else { '' })
    $short = Format-Icon $iconCtx "$pct% $bar"
    return @{ Name = 'context'; Text = "$short$tail"; Short = $(if ($tail) { $short } else { $null }); Role = $role; Bold = $false }
}

# ---- Prompt cache warmth ----
# THE ONE THING TO GET STRAIGHT BEFORE READING THESE THREE: they do not answer the question
# Get-CacheShare answers, and the two must not be folded together. Get-CacheShare reads
# context_window.current_usage and gives the share of THIS TURN'S input the cache served - a hit ratio,
# printed as the context segment's dim "92% cached". These read the prompt_cache block and give whether
# the cache is alive at all and for how long. Different block, different question, no shared arithmetic.
# A turn can honestly be 92% cached off a cache with four minutes left to live, and that pair - a good
# ratio beside a lapsing window - is exactly the moment the segment exists to show, so both belong on
# the line at once. Neither figure is derivable from the other.

# Seconds until the prompt cache expires, or $null when the payload's expires_at could not be one.
# The field is epoch seconds, like rate_limits.five_hour.resets_at, but it is not documented with a
# unit, so a client sending milliseconds is a real possibility: a value past 1e12 - year 33658 read as
# seconds, which no cache expiry is - is divided by 1000 first.
# WHAT IS REFUSED, AND WHY REFUSED RATHER THAN CLAMPED. A value that is not a finite number is not a
# time. A value at or below 0 is 1970 or earlier, and calling that "expired" would let a plainly
# malformed field print a confident red "cache cold" - a definite claim built out of nothing. And a
# value more than a day out is refused for the same reason: the longest prompt cache lifetime Anthropic
# documents is an hour, so a day is generous head-room and still refuses the far-future epochs payloads
# really carry - sample 06's 4102444800 is 1 January 2100, which the rate-limit countdown beside this
# one renders as a nonsense "(26781d)". Clamping any of these to a boundary would put a number on the
# line that reads as fact; refusing leaves the caller to say "warm, and I cannot tell you how long",
# which is the honest answer and the one an absent field already gets.
# $Now is the epoch this countdown is measured against, and it DEFAULTS TO THE SEAM rather than to a
# clock of its own, so this countdown, the rate-limit one beside it and the wall clock at the end of
# the line all come out of one reading and a screenshot can be regenerated to the same bytes. The
# default is what carries that, not the call site: a caller that says nothing about time gets the
# render's reading, and the four separate readings this seam exists to remove cannot come back one
# forgotten argument at a time. Unpinned, Get-StatusClock is the machine's clock, which is what a test
# calling this directly gets and what production got before.
# The value stays a whole-second epoch rather than a DateTimeOffset because subtracting two numbers
# cannot throw the way constructing a date out of an absurd one can; the same reason TimeLeft and
# Get-PaceArrow take theirs that way.
# The cast to [long] rather than [int] is what keeps this total over its domain. The two guards bound
# the top at 86400 and, through refusing an expiry of 0 or less, the bottom at -$Now - and -$Now was
# comfortably inside an Int32 only while $Now was a reading of the clock. A $Now the caller chose
# (CLAUDE_STATUSLINE_NOW naming a far-future year, or this machine's own clock after 2038) makes the
# difference wider than an Int32, and an [int] cast on it fails, which under this script's
# SilentlyContinue is SILENT: the function answered nothing, and nothing reads as "warm, and I cannot
# tell you how long" over a cache that had been cold for decades - the most reassuring thing on the
# line at the moment it was least true. [long] holds every difference the seam can produce, so the
# answer stays a real count of seconds and no value is clamped into one, which is the rule the
# refusals above already follow. (Found by the Codex review of the seam.)
function Get-CacheSecondsLeft($Value, [long] $Now = ((Get-StatusClock).ToUnixTimeSeconds())) {
    $at = Get-FiniteNumber $Value
    if ($null -eq $at) { return $null }
    if ($at -gt 1e12) { $at = $at / 1000 }
    if ($at -le 0) { return $null }
    $left = $at - $Now
    if ($left -gt 86400) { return $null }
    return [long] [math]::Floor($left)
}

# A count of whole seconds as the text the segment prints: "<1m" under a minute, "42m" under an hour,
# "2h05m" above it - the same h{mm}m shape TimeLeft uses for the rate-limit reset, so the two countdowns
# that can share a line are read the same way. Minutes are floored rather than rounded, because a
# countdown that says 5m with four and a half minutes left is telling you there is more time than there
# is. Callers pass a positive count and the ceiling above caps it at a day, so the widest this returns
# is "24h00m".
function Format-MinutesLeft([int] $Seconds) {
    if ($Seconds -lt 60) { return '<1m' }
    $minutes = [int] [math]::Floor($Seconds / 60)
    if ($minutes -lt 60) { return "${minutes}m" }
    return '{0}h{1:00}m' -f [int] [math]::Floor($minutes / 60), ($minutes % 60)
}

# The five-minute line: at or below it the segment is a warning, above it it is calm. Five minutes is
# about one long turn, so it is the point where "send a cheap keep-alive now" stops being premature.
# THIS IS A FUNCTION RATHER THAN AN INLINE COMPARISON FOR A TESTING REASON, and it is the same reason
# Get-ThresholdRole is one. A boundary that lives inside a builder can only be reached through a
# payload, and a payload's expires_at is measured against a clock read at one instant while the builder
# reads its own an instant later. One tick turns an intended 300 into 299 - still 'warn', so the test
# passes either way, and a `-lt 300` mutant survives it. Worse, the same tick turns the rendered text
# from 5m into 4m, which fails correct code. As a pure function of whole seconds the boundary is pinned
# exactly, with no clock between the input and the answer, and the builder's own cases can then sit
# safely mid-minute where drift cannot reach them.
function Get-CacheRole([int] $Seconds) { if ($Seconds -le 300) { 'warn' } else { 'ok' } }

# Whether the prompt cache is still warm and how long it has left: "cache 42m" in green, "cache 4m" in
# yellow inside the last five minutes, "cache cold" in red once it has lapsed, and "cache off" in red
# when the client has been asking for caching and has never seen it work. A cache miss costs real money
# and real latency, so a window about to close is the difference between sending a cheap keep-alive turn
# and taking a break; a cache that is not working at all is worth interrupting for.
# The block arrived in Claude Code 2.1.251 and is absent both on older versions and early in a session,
# so the segment has to disappear cleanly rather than render an empty shape - which is the last rule
# below and the one the omission cases are written around.
# The order of the four states is the whole logic and it is not arbitrary:
#   1. Nothing usable. Neither a boolean `warm` nor an expires_at this script will believe means there
#      is no question to answer, so there is no segment. This is also where a payload from an older
#      Claude Code lands.
#   2. Cold. `warm` is the boolean false, or the expiry has already passed. An expiry in the past beats
#      a `warm` beside it that says true: the timestamp is the specific claim and the flag is the
#      summary, and a summary that contradicts its own timestamp is the one to distrust.
#   3. Off. `caching_observed` is the boolean false with at least three requests behind it. The field is
#      false until the client has actually seen a hit, so it says nothing at all on the first turn or
#      two; three requests is where it starts to mean "asked for, never delivered". This is checked
#      BEFORE the countdown, because it is the more specific claim: a cache the client says is not
#      working has an expires_at like any other, and printing that countdown over it would be the most
#      reassuring thing on the line at the moment it is least true. It is allowed to fire with `warm`
#      absent as well as true, for the same reason - gating the warning on a field that may simply not
#      be there would restore exactly the countdown it exists to suppress. A `requests` that is not a
#      whole positive count cannot reach three, so a malformed one refuses to make the claim rather than
#      being repaired into it.
#   4. Warm. With a believable expiry, the countdown, yellow inside five minutes. Without one - refused
#      as nonsense, or simply absent - the word "warm" and no number, because `warm` on its own is a
#      real answer to "is the cache alive" and the honest thing is to leave the part we cannot tell off
#      the line rather than invent it.
# ON QUIET: this segment deliberately has no `quiet` key, and adding one would break the rule that quiet
# never hides a segment carrying a warning, an error or an alarm. Three of its four states - cold, off
# and the last five minutes - ARE that warning, and the fourth is a countdown whose whole value is being
# there before it turns yellow. There is no boring number here to hide, so there is nothing for a
# threshold to be a threshold on, and Test-QuietValue is never asked about 'cache'.
# Short drops the word and keeps the glyph and the value, so a narrow line reads as a fire and "42m".
function Get-CacheSegment($d) {
    $pc = $d.prompt_cache
    if ($pc -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $warm = if ($pc.warm -is [bool]) { [bool] $pc.warm } else { $null }
    $left = Get-CacheSecondsLeft $pc.expires_at
    if ($null -eq $warm -and $null -eq $left) { return $null }
    if ($warm -eq $false -or ($null -ne $left -and $left -le 0)) {
        return @{ Name = 'cache'; Text = (Format-Icon $iconCache 'cache cold'); Short = (Format-Icon $iconCache 'cold'); Role = 'bad'; Bold = $false }
    }
    $requests = Get-PayloadNumber $pc.requests
    if ($pc.caching_observed -is [bool] -and -not $pc.caching_observed -and $null -ne $requests -and $requests -ge 3) {
        return @{ Name = 'cache'; Text = (Format-Icon $iconCache 'cache off'); Short = (Format-Icon $iconCache 'off'); Role = 'bad'; Bold = $false }
    }
    if ($null -eq $left) {
        return @{ Name = 'cache'; Text = (Format-Icon $iconCache 'cache warm'); Short = (Format-Icon $iconCache 'warm'); Role = 'ok'; Bold = $false }
    }
    $value = Format-MinutesLeft $left
    $role = Get-CacheRole $left
    return @{ Name = 'cache'; Text = (Format-Icon $iconCache "cache $value"); Short = (Format-Icon $iconCache $value); Role = $role; Bold = $false }
}

# Session cost in dollars, two decimals, and the change since the previous render in parentheses behind
# it, "$1.07 (+$0.12)", so the turn just paid for is visible and not only the running total that tells
# you nothing about it. The previous total is $state.cost_usd, the figure the last render of this session
# wrote; no state file, a first render, a total that did not move and one that went backwards (a state
# file carried between machines) all print the total alone, which is exactly what this segment was before
# the delta existed. With statusLine.refreshInterval set the command re-runs on a timer, so a render with
# no API call behind it shows no suffix until the next turn.
# "The previous render" is exactly the last render that wrote the file, which is not always the last
# render there was: one that ends before the write - the zero-segment exit does - leaves the next delta
# spanning both turns. That figure is still the difference between two totals this session really
# reached, and a render that wrote nothing printed no total of its own for it to contradict.
# The delta is rounded to cents once, and both the "is this worth showing" test and the printed figure
# read that one number: binary floating point makes 1.08 - 1.07 a hair over a cent and 0.03 - 0.02 a hair
# under, and rounding first is what stops those two from being answered differently. Both figures go
# through the same '{0:N2}', so a culture that writes 12,50 writes the delta the way it writes the total
# beside it.
# Short is the total on its own, and $null when there is no delta, so the fitting sheds the suffix first
# of anything on the line and a cost with no delta is skipped in stage one as it always was.
# quiet.cost is tested on the raw figure rather than on the text, so a threshold of 1 hides a cost of
# 0.996 even though it would have printed $1.00. It is tested on the session total and not on the delta:
# the threshold answers whether this session is worth a segment, not whether this turn was expensive, and
# a segment the guard hides has no suffix to argue about.
# There is no warning state to preserve here, unlike context and limits: this segment's role is always
# dim, no config threshold colours it, and no alarm is read against a dollar figure - Test-AlarmState
# asks only the context window and the two rate limits - so a spend the user called boring is only ever
# boring and the quiet guard stands alone.
function Get-CostSegment($d, $cfg, $state) {
    # Get-FiniteNumber rather than a null check and a bare [double] cast on display: the cast is typed
    # but is not a guard, and under this script's SilentlyContinue a hostile total_cost_usd survives the
    # failed cast rather than becoming an error - a boolean $true satisfies [double] as 1.0 and prints a
    # confident "$1.00" (code review, the same shape as the used_percentage finding on Get-ContextSegment).
    $cost = Get-FiniteNumber $d.cost.total_cost_usd
    if ($null -eq $cost) { return $null }
    if (Test-QuietValue $cfg 'cost' $cost) { return $null }
    $total = Format-Icon $iconCost ("`$" + ('{0:N2}' -f $cost))
    # Both sides go through Get-CountedNumber, so a figure of any other shape, and a negative on either
    # side, is simply a render with no delta: this arithmetic never decides whether the segment appears
    # at all. The stored total is the side that matters - a hand-edited record holding -100 against a
    # real total of 1.07 would otherwise render a confident (+$101.07). The payload's own total is asked
    # the same question even though nothing today can reach a wrong answer through it: a negative
    # payload total against an honest record makes the subtraction negative, which the rule below
    # refuses anyway, and against a negative record the record is refused first. It is written as the
    # invariant rather than left resting on that coincidence, because the coincidence belongs to the
    # "at least a cent" rule and would go with it.
    $suffix = ''
    $spent = Get-CountedNumber $cost
    $before = Get-CountedNumber $state.cost_usd
    if ($null -ne $spent -and $null -ne $before) {
        $delta = [math]::Round($spent - $before, 2)
        if ($delta -ge 0.01) { $suffix = " (+`$" + ('{0:N2}' -f $delta) + ')' }
    }
    return @{ Name = 'cost'; Text = "$total$suffix"; Short = $(if ($suffix) { $total } else { $null }); Role = 'dim'; Bold = $false }
}

# A count of milliseconds as one short elapsed string, or $null when it is not a duration any session
# could have run for. Three forms: `<1m` under a minute, `12m` under an hour, and `1h12m` above one,
# with the minutes zero-padded so an hour and five reads as 1h05m rather than as 1h50m.
# Refusing rather than repairing is the whole of the guard, and the reason is that every repair here
# produces a reading that looks real. Minus twenty minutes clamped to zero prints `<1m` and reads as a
# session that has just started; a NaN clamped the same way reads identically; there is no elapsed time
# that says "we cannot tell", so the segment goes instead. The upper end is refused on the same terms
# rather than pinned to the largest value that fits: past what a [TimeSpan] can hold, a count of
# milliseconds is not an interval at all. Going through a TimeSpan is also what keeps the format honest -
# the total hours of a span that is in range fit an Int32, so the hours can never reach the scientific
# notation a bare double would print.
# Separate from Get-ClockSegment so the three forms and the refusals can be tested without a payload,
# and separate from TimeLeft, which counts down to an epoch and has a days form this does not want: a
# session is measured in the hours it has run, not rounded off to `2d`.
function Format-Elapsed([object] $ms) {
    $n = Get-FiniteNumber $ms
    if ($null -eq $n -or $n -le 0) { return $null }
    $span = try { [TimeSpan]::FromMilliseconds($n) } catch { return $null }
    if ($span.TotalMinutes -lt 1) { return '<1m' }
    if ($span.TotalHours -lt 1) { return '{0}m' -f $span.Minutes }
    return '{0}h{1:00}m' -f [int] [math]::Floor($span.TotalHours), $span.Minutes
}

# How long the session has been running and how much of that went on waiting for the model:
# `1h12m · api 38%`. Dim and never bold, with no threshold band and no alarm behind it, because a long
# session is not an error - it is the one figure on the line that says nothing about what the session is
# doing right now, which is also why it is the first whole segment worth dropping once the lines
# counts have gone. It goes ahead of the cache segment, which is the other candidate for that slot:
# both are arguably the least urgent number on the line, but this one is dim by construction and that
# one has a warn band and two bad states, and a dropped segment takes its colour with it.
# The separator is a middle dot with a space either side rather than a dash: a dash beside a percentage
# reads as a range.
# The share goes through Get-WholePercent, the one percentage rule on the line. It is not a candidate for
# the [math]::Floor exception subagent-statusline.ps1 documents: that exception exists to stop a colour
# band running ahead of the number under it, and nothing bands on this figure.
# An api figure that could not be true is refused rather than clamped into range. A session cannot have
# spent longer waiting on the API than it has existed, so a payload claiming it did is not a share to pin
# at 100 - it is a pair of figures with nothing to say about the split, and the elapsed time on its own
# is the honest answer, which is the answer a payload carrying no api figure at all already gets.
# Clamping a figure that cannot be true is how a negative token count came to render `100% cached` and a
# negative stored total a confident `+$101.07`.
# The short form is the elapsed time without the share, and it is the last detail stage one of the
# fitting sheds. No share means no short form, so a render with nothing to shed costs the fitting nothing,
# the same way the cost segment's does.
function Get-ClockSegment($d, $cfg) {
    $elapsed = Format-Elapsed $d.cost.total_duration_ms
    if (-not $elapsed) { return $null }
    $text = Format-Icon $iconClock $elapsed
    # Format-Elapsed answered, so the total is a finite number above zero and the division below is safe.
    $total = Get-FiniteNumber $d.cost.total_duration_ms
    $api = Get-FiniteNumber $d.cost.total_api_duration_ms
    $share = ''
    if ($null -ne $api -and $api -gt 0 -and $api -le $total) {
        $share = ' ' + (Get-MarkSet $cfg.Style).Middot + ' api ' + (Get-WholePercent ($api / $total * 100)) + '%'
    }
    return @{ Name = 'clock'; Text = "$text$share"; Short = $(if ($share) { $text } else { $null }); Role = 'dim'; Bold = $false }
}

# The wall clock, `14:05`: the local time of day, 24-hour, the way a shell prompt puts the time on the
# right of the line. Dim and never bold, with no threshold band and no alarm behind it, because a clock
# is not a state.
#
# THIS IS NOT THE CLOCK SEGMENT ABOVE. Get-ClockSegment prints how long this session has been running
# and what share of that went on the API; both are times and neither is the other. A session that has
# run 1h12m says nothing about whether it is now 09:14 or 23:47, and the figure worth having beside a
# right edge is the one a shell prompt puts there. Two segments, two numbers, two glyphs - a stopwatch
# for the elapsed time and a wall clock for the time of day.
#
# It reads no payload field, because there is none to read: Claude Code's payload carries no timestamp,
# so the machine's own clock is the only source there is. That makes it the one segment whose value
# moves without a new payload, which is why the README says to set statusLine.refreshInterval beside it.
# Without one the script runs only on Claude Code's events, so an idle session shows the time of the
# last event rather than the time now - a stale clock, and a clock that is quietly wrong is worse than
# no clock at all, which is why the default is off and why the note is beside the segment and not in a
# footnote.
#
# The colon is escaped in the format string. `:` in a .NET custom format is the culture's time separator,
# which under fi-FI is a dot, and `14.05` is not what this segment or the README says it prints.
# No Short form: there is nothing in five characters to shed. It takes DropRank 1 instead - the first
# whole segment to go - because it is the one figure on the line that says nothing about the session.
# The three parameters are what the build loop hands every builder; this one uses none of them, and
# naming them rather than leaving them in $args is what says so.
#
# The reading is the render's one reading rather than a Get-Date of its own (see Get-StatusClock at the
# head of this file), which is what lets the two-line screenshot be regenerated to the same bytes: this
# is the segment that used to make that impossible. A DateTimeOffset formats at ITS OWN offset, so an
# unset CLAUDE_STATUSLINE_NOW leaves this the machine's local time exactly as before, and a pinned
# instant prints the wall clock of the offset it carries, the same string in any zone.
function Get-TimeSegment($d, $cfg, $state) {
    return @{ Name = 'time'; Text = (Format-Icon $iconTime ((Get-StatusClock).ToString('HH\:mm'))); Short = $null; Role = 'dim'; Bold = $false }
}

# Lines added/removed this session; shown when either is non-zero. Inline colours keep the dim background intact.
function Get-LinesSegment($d, $cfg) {
    # Get-PayloadNumber rather than a bare [int] cast: the cast is typed but is not a guard, and under
    # this script's SilentlyContinue a hostile total_lines_added or total_lines_removed survives the
    # failed cast as an empty string rather than becoming an error, printing "+ " with nothing after it
    # (code review, the same shape as the used_percentage finding on Get-ContextSegment). A count that is
    # missing or unusable is treated as zero either way, which is what "??" already did for missing.
    $added = (Get-PayloadNumber $d.cost.total_lines_added) ?? 0
    $removed = (Get-PayloadNumber $d.cost.total_lines_removed) ?? 0
    if ($added -le 0 -and $removed -le 0) { return $null }
    $minus = (Get-MarkSet $cfg.Style).Minus
    $text = Format-Icon $iconLines ((Format-Inline 'added' "+$added" 'dim' $cfg.Style $cfg.Palette 'lines' $cfg.Tint) + ' ' + (Format-Inline 'removed' ($minus + "$removed") 'dim' $cfg.Style $cfg.Palette 'lines' $cfg.Tint))
    return @{ Name = 'lines'; Text = $text; Short = $null; Role = 'dim'; Bold = $false }
}

# " (1h12m)" or " (3d)" until the given epoch; empty when absent, already past, not a number at all
# (a hostile string, a boolean, NaN, infinity - the same Get-FiniteNumber gate every other payload
# number in this script goes through), under a minute out, or more than a year out - a reset that far
# away is not a countdown anyone is pacing against, and the honest answer is silence rather than a
# five-digit day count nobody asked for.
# The arithmetic stays in whole seconds against $Now, the same shape Get-PaceArrow and
# Get-CacheSecondsLeft already use for the identical hazard: a numerically valid but absurd epoch such
# as 1e18 used to throw straight out of DateTimeOffset::FromUnixTimeSeconds and take the whole limits
# segment down with it, and subtracting two numbers cannot throw the way constructing a date from one
# of them can. The 60-second floor and the 31536000-second (365-day) ceiling are what used to be a
# separate DateTimeOffset range check plus a TotalMinutes/TotalDays test on the result; bounding $left
# first means TimeSpan::FromSeconds below is always given a value it can hold, so it is formatting, not
# guarding. $Now defaults to the seam, the same way Get-CacheSecondsLeft's does and for the same
# reason: this countdown, the pace arrow beside it and the cache countdown on the same line then come
# out of one reading whoever calls them, and a call site that forgets to say so cannot put them back on
# separate clocks. Unpinned it is the machine's clock, which is what a test calling this directly gets
# and what it wants - a $Now that stays put while a boundary is checked.
function TimeLeft([object] $epoch, [long] $Now = ((Get-StatusClock).ToUnixTimeSeconds())) {
    $sec = Get-FiniteNumber $epoch
    if ($null -eq $sec) { return '' }
    $left = $sec - $Now
    if ($left -lt 60 -or $left -gt 31536000) { return '' }
    $span = [TimeSpan]::FromSeconds($left)
    if ($span.TotalHours -ge 48) { return ' ({0}d)' -f [int] [math]::Floor($span.TotalDays) }
    return ' ({0}h{1:00}m)' -f [int] [math]::Floor($span.TotalHours), $span.Minutes
}

# How the 5-hour window is being spent, as one plain arrow: U+2192 when carrying on at this rate lands
# inside the window, U+2191 when it overruns, with Red set once the projection reaches 120% so the caller
# can colour it. Returned as @{ Arrow; Red }, or $null for no arrow at all - which is the answer whenever
# there is nothing honest to say: no reset time, a reset already past or one so far out that the window
# has not opened, less than the first tenth of the window gone (one busy minute swings the projection
# there), or no usage yet, where every projection is zero and a right arrow would just be noise.
# The window is a fixed 18000 seconds, so the elapsed fraction follows from the reset alone and no state
# file is needed. The arithmetic stays in whole seconds rather than DateTimeOffset, which throws on an
# epoch outside its own range; a payload's absurd number here just falls out as no arrow. The two limits
# are tested on the seconds left rather than on the fraction, because a tenth of the window is 16200
# seconds exactly while 1 - 16200 / 18000 is 0.09999999999999998, which would drop the first honest
# reading of every window.
# $Now defaults to the seam, so the arrow and the countdown beside it project from one reading without
# either call site having to say so. Unpinned it is the machine's clock, which is what a test calling
# this directly gets: an epoch derived from an earlier reading is one second out whenever the second
# ticks in between, which is enough to miss both of the limits above by exactly the margin a regression
# would move, so a test that means to sit on a boundary passes its own $Now.
function Get-PaceArrow([object] $resetsAt, [object] $used, [long] $Now = ((Get-StatusClock).ToUnixTimeSeconds()), [string] $Style) {
    $reset = Get-FiniteNumber $resetsAt
    $pct = Get-FiniteNumber $used
    if ($null -eq $reset -or $null -eq $pct -or $pct -le 0) { return $null }
    $left = $reset - $Now
    if ($left -le 0 -or $left -gt 16200) { return $null }
    $projected = $pct * 18000 / (18000 - $left)
    # Over names the state the up arrow draws: this rate overruns the window. The quiet guard reads it
    # rather than the glyph, because it is the warning that must survive a threshold, not the character.
    # $Style only picks the character; Over and Red are the same figures whatever is drawn for them.
    $mark = Get-MarkSet $Style
    if ($projected -le 100) { return @{ Arrow = $mark.Steady; Over = $false; Red = $false } }
    return @{ Arrow = $mark.Rising; Over = $true; Red = ($projected -ge 120) }
}

# Rate limits: 5-hour and 7-day usage, plus time until the 5-hour window resets, and the spend limit when
# the payload carries one (Claude Code sends it behind a Claude apps gateway with a spend limit). The spend
# figure uses a literal dollar sign, not the cash glyph, so it does not read as a second cost; its resets_at
# is not shown, one countdown is enough. Every figure that is present joins the worst-of colour, banded by
# the config's thresholds whatever the window size, and the Short form a narrow terminal falls back to
# keeps the figure behind that colour: the worst one, or the first present one when nothing is above the
# warn line. Either way it carries neither the countdown nor the pace arrow.
# The 5-hour figure also gets the pace arrow, between the percentage and the countdown, because that is
# the only window one payload can honestly pace. It is added after the loop rather than inside it: a red
# arrow goes through Format-Inline, which hands the segment's own foreground back afterwards, and which
# foreground that is depends on every figure the loop has yet to see.
function Get-LimitsSegment($d, $cfg) {
    $rl = $d.rate_limits
    if (-not $rl) { return $null }
    $bits = [System.Collections.Generic.List[string]]::new()
    $worst = -1
    $windowWorst = $null
    $first = $null
    $top = $null
    $pace = $null
    $paceAt = -1
    $paceHead = ''
    $paceTail = ''
    # Label, source object, whether the pace arrow and the countdown follow, and whether the figure is a
    # rate-limit window rather than the spend limit, in render order.
    foreach ($row in @(@('5h', $rl.five_hour, $true, $true), @('7d', $rl.seven_day, $false, $true), @('$', $rl.spend_limit, $false, $false))) {
        # Get-FiniteNumber is the same gate every other payload number in the script goes through - true
        # when this was written only of the numbers that already used it; code review found
        # Get-ContextSegment, Get-CostSegment and Get-LinesSegment reading theirs with a null check and
        # a typed cast instead, which is not a guard under this script's SilentlyContinue (a hostile
        # value survives the failed cast rather than raising an error), and they now go through it too
        # (via Get-PayloadPercent for the one percentage among them, Get-PayloadNumber for the two line
        # counts). A string, a boolean ($true would otherwise coerce to 1 and print "5h 1%"), an array
        # or a null all come back $null here and this figure alone is left off the line, the way a
        # missing used_percentage always has been - the loop's own worst-of and countdown logic never
        # sees it, so one bad figure never takes the other two, or the segment, down with it.
        $pct = Get-FiniteNumber $row[1].used_percentage
        if ($null -eq $pct) { continue }
        $pct = Get-WholePercent $pct
        $bit = "$($row[0]) $pct%"
        if ($null -eq $first) { $first = $bit }
        # A strict comparison keeps the earlier figure on a tie, so 5h beats 7d beats spend.
        if ($pct -gt $worst) { $top = $bit; $worst = $pct }
        # The largest of the two rate-limit windows, kept apart from $worst because quiet.limits is a
        # threshold on how much of an allowance is gone, and the spend limit is not one of those. $null
        # until a window is actually present, which is what a payload carrying only a spend limit leaves.
        if ($row[3] -and ($null -eq $windowWorst -or $pct -gt $windowWorst)) { $windowWorst = $pct }
        $tail = ''
        if ($row[2]) {
            # Neither call names a clock: both default to the render's one reading (see Get-StatusClock),
            # so the countdown and the projection beside it cannot land in different minutes.
            $tail = TimeLeft $row[1].resets_at
            # The raw percentage, not the rounded one: the projection is the arrow's whole point.
            $pace = Get-PaceArrow $row[1].resets_at $row[1].used_percentage -Style $cfg.Style
            if ($pace) { $paceAt = $bits.Count; $paceHead = $bit; $paceTail = $tail }
        }
        $bits.Add("$bit$tail")
    }
    if ($bits.Count -eq 0) { return $null }
    # ORDER MATTERS here the same way it does in Get-ContextSegment. Each figure is normalised to a whole
    # percent inside the loop above - by Get-WholePercent, the rule the alarm compares against too -
    # $worst and $windowWorst are accumulated from those normalised figures, the role is read from
    # $worst, and only then is the quiet guard asked, with the role, the pace arrow and the alarm all
    # settled in front of it. Whoever changes how a figure is normalised must keep that chain: a role
    # read from a raw payload figure would band the wrong number, and the guard would then hide a
    # segment the wrong colour says is calm. The pace arrow below is the one deliberate exception, and
    # says so: it needs the raw figure because it is projecting from it.
    $role = Get-ThresholdRole $worst $cfg.Thresholds.Warn $cfg.Thresholds.Bad
    # quiet.limits is tested on the larger of the two rate-limit windows, not on $worst, which also
    # carries the spend limit and stays the colour-driving figure. Three guards stand in front of it,
    # all the rule above: a segment already yellow or red is an alarm, so is a five-hour figure whose
    # projection overruns the window - that is the case a threshold would otherwise swallow at its most
    # dangerous, because a low current percentage early in a window is exactly what projects red - and
    # so is a window figure at or above alarm.limits, which is allowed to sit below thresholds.warn and
    # would otherwise turn the model red with no tachometer under it saying which limit it is. That last
    # test reads $windowWorst, the same pair of windows Test-AlarmState reads for the model segment; the
    # spend limit raises no alarm there and is not compared here either. With neither window present
    # there is nothing to compare, and both Test-AlarmLevel and Test-QuietValue answer false on the
    # $null, so a payload carrying only a spend limit is never hidden by this key.
    if ($role -eq 'ok' -and -not ($paceAt -ge 0 -and $pace.Over) -and -not (Test-AlarmLevel $windowWorst $cfg.Alarm.Limits) -and (Test-QuietValue $cfg 'limits' $windowWorst)) { return $null }
    if ($paceAt -ge 0) {
        $arrow = if ($pace.Red) { Format-Inline 'removed' $pace.Arrow $role $cfg.Style $cfg.Palette 'limits' $cfg.Tint } else { $pace.Arrow }
        $bits[$paceAt] = "$paceHead $arrow$paceTail"
    }
    $text = Format-Icon $iconLimit ($bits -join ' ')
    $short = Format-Icon $iconLimit $(if ($role -eq 'ok') { $first } else { $top })
    if ($short -eq $text) { $short = $null }
    return @{ Name = 'limits'; Text = $text; Short = $short; Role = $role; Bold = $false }
}

# Session badges in two groups. First the modes - fast mode, thinking, non-default effort, vim mode -
# which come and go as the session runs, so they hold the left of the segment where the eye already
# looks for them. Then the identities: the custom agent driving the main thread and the name the user
# gave this session, both of which stay put for a whole session, so they sit on the right where a
# change is not expected. The segment is omitted when neither group has anything, which now means a
# session with every mode off still gets a badges segment once it is named or run by an agent.
# agent.name and session_name are payload text, so they go through the same pair the branch name and
# the repo owner go through: Test-PayloadText decides whether there is anything there at all (a control
# character, a blank, a number, or a string of nothing but format characters is not a name), and
# Format-PayloadText strips the format characters out of what is left, so neither badge can reorder or
# hide the rest of the line. Then Get-ClippedText cuts each one to $badgeNameCells cells, measured the
# way the fitting code measures, so a name in wide characters cannot take twice the room it was given.
# effort.level and vim.mode are payload text too, from Claude Code itself rather than from anything an
# attacker authors, but the guards exist so that no payload field is trusted individually - the same
# two-call shape, applied here so it is not the one left for someone to copy without it. The effort
# comparison against $defaultEffort is OrdinalIgnoreCase rather than PowerShell's own -eq: #61 asked
# for a comparison a culture cannot bend, not a new case-sensitivity cliff where "HIGH" stops meaning
# the default it always meant. -eq's actual defect is the one -ceq shares and OrdinalIgnoreCase does
# not: giving a Unicode Format character zero collation weight, the trap documented at the top of
# test.ps1, so "high<U+200D>" would read as the plain word under either -eq or -ceq. That trap cannot
# reach this comparison at all, format characters or not, because Format-PayloadText already stripped
# them out of $effort above; OrdinalIgnoreCase is what is left once culture and case both stop
# mattering, and it is what keeps this call the ordinary "which word is this" question the default was
# always answering.
# Short is the modes alone, so a narrow line sheds the two identities before the whole segment goes;
# it is $null when there is nothing to shed - no modes, or no identities - the way Get-LimitsSegment
# leaves its Short $null rather than repeating the full text.
# fast_mode and thinking.enabled are read with the same "-is [bool] -and" test exceeds_200k_tokens
# already used below: PowerShell's own -eq is not a type check, so a plain -eq $true reads the string
# "true" or the number 1 as true too, and neither is the boolean Claude Code actually sends (code
# review: found while checking whether all six badge fields go through the same guard).
function Get-BadgesSegment($d) {
    $badges = [System.Collections.Generic.List[string]]::new()
    if ($d.fast_mode -is [bool] -and $d.fast_mode) { $badges.Add($iconFast) }
    if ($d.thinking.enabled -is [bool] -and $d.thinking.enabled) { $badges.Add($iconThink) }
    $effort = Get-PayloadText $d.effort.level
    if ($null -ne $effort -and -not [string]::Equals($effort, $defaultEffort, [System.StringComparison]::OrdinalIgnoreCase)) { $badges.Add((Format-Icon $iconEffort $effort)) }
    $vim = Get-PayloadText $d.vim.mode
    if ($null -ne $vim) { $badges.Add((Format-Icon $iconVim $vim)) }
    $modeCount = $badges.Count
    $modes = if ($modeCount -gt 0) { $badges -join ' ' } else { $null }
    $agentName = Get-PayloadText $d.agent.name
    if ($null -ne $agentName) { $badges.Add((Format-Icon $iconAgent (Get-ClippedText $agentName $badgeNameCells))) }
    $sessionName = Get-PayloadText $d.session_name
    if ($null -ne $sessionName) { $badges.Add((Format-Icon $iconSession (Get-ClippedText $sessionName $badgeNameCells))) }
    if ($badges.Count -eq 0) { return $null }
    $short = if ($modes -and $badges.Count -gt $modeCount) { $modes } else { $null }
    return @{ Name = 'badges'; Text = ($badges -join ' '); Short = $short; Role = 'dim'; Bold = $false }
}

# ---- Links. One switch and two URL builders, shared by the pr, folder and branch segments. ----

# The switch. `links` is one key for every hyperlink on the line rather than one per segment, because
# the reason to turn them off is never about a segment: it is a terminal that prints the escape as text
# instead of swallowing it, and that terminal is broken for all three at once. The key defaults to true,
# so only the boolean false turns them off; a config that does not name the key, and a builder called
# with no config at all, get the default.
function Test-LinkWanted($cfg) { return ($cfg.Links -ne $false) }

# The folder segment's URL: the session's directory as a file: URL, so ctrl-click opens it. TryCreate
# rather than a [uri] cast, because the cast throws on anything that is not an absolute URI and this
# runs on every render; AbsoluteUri then does the escaping, so C:\src\my project becomes
# file:///C:/src/my%20project and a # in a directory name becomes %23 instead of opening a fragment.
# Three answers of $null, each rendering the segment unlinked rather than guessing: a path that is not
# an absolute URI at all (a relative one, a bare name, an empty string, a value that is not a string),
# a path that parses as something other than a file (current_dir is a payload field, and
# "https://evil.example/x" parses perfectly well as an absolute URI), and a UNC path, whose authority
# is a machine name. $Dir is untyped for the usual reason: a [string] parameter would join an array
# into a path instead of refusing it.
function Get-FolderUrl($Dir) {
    if ($Dir -isnot [string] -or -not $Dir) { return $null }
    $uri = $null
    if (-not [System.Uri]::TryCreate($Dir, [System.UriKind]::Absolute, [ref] $uri)) { return $null }
    if (-not $uri.IsFile -or $uri.Host) { return $null }
    return $uri.AbsoluteUri
}

# The branch segment's URL, from workspace.repo, which the payload carries only for a checkout with a
# recognised remote. github.com gets the branch page, /<owner>/<name>/tree/<branch>; every other host
# gets the repository home, /<owner>/<name>. GitLab spells a branch /-/tree/, Bitbucket /src/ and Azure
# DevOps something else again, and a wrong guess lands the click on a 404, while a repository home is
# right everywhere. https always: the field is a host name rather than a URL, and there is no reason to
# send a click over plaintext.
# Every field here is repository-supplied text - a remote is written by whoever made the checkout - so
# each is guarded rather than pasted in. The host has to look like a host and nothing else: a "host" of
# "evil.example/a?" would put the owner and the name in a query string on somebody else's site, and one
# carrying an @ would make the whole thing userinfo in front of a different host again. The owner and
# the name go through EscapeDataString, so a slash in either cannot climb the path. The branch is
# escaped a segment at a time, which keeps the slash in feature/x, where it is a real separator on the
# branch page, and still turns a space into %20 and a # into %23; EscapeUriString, which the issue
# suggested, leaves the # alone and would truncate the URL into a fragment. Format-Link is still the
# last gate on all of it. A detached HEAD gets no link: "detached" is the word this script prints for
# the state, not a ref anything can be looked up by.
function Get-BranchUrl($d, [string] $Branch) {
    if (-not $Branch -or $Branch -eq 'detached') { return $null }
    $repo = $d.workspace.repo
    $repoHost = Get-PayloadText $repo.host
    $repoOwner = Get-PayloadText $repo.owner
    $repoName = Get-PayloadText $repo.name
    if ($null -eq $repoHost -or $null -eq $repoOwner -or $null -eq $repoName) { return $null }
    if ($repoHost -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$') { return $null }
    $owner = [uri]::EscapeDataString($repoOwner)
    $name = [uri]::EscapeDataString($repoName)
    $url = "https://$repoHost/$owner/$name"
    if (-not [string]::Equals($repoHost, 'github.com', [System.StringComparison]::OrdinalIgnoreCase)) { return $url }
    $parts = $Branch -split '/'
    for ($i = 0; $i -lt $parts.Count; $i++) { $parts[$i] = [uri]::EscapeDataString($parts[$i]) }
    return "$url/tree/$($parts -join '/')"
}

# The pull request on the session's branch: the glyph and #number, the whole text wrapped in a link to
# pr.url, coloured by pr.review_state - approved is ok, changes requested (spaces or underscores, any
# case) is bad, anything else is dim, including a state that is not text at all. The number goes
# through Get-PayloadNumber and has to be positive; without one there is no segment, whatever else the
# object holds. The url goes to Format-Link as it is, which leaves the text unlinked for anything that
# is not a plain http(s) URL. pr.kind is not rendered. Omitted when the payload has no pr object, or
# has something other than an object there.
function Get-PrSegment($d, $cfg) {
    $pr = $d.pr
    if ($pr -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $number = Get-PayloadNumber $pr.number
    if ($null -eq $number -or $number -le 0) { return $null }
    $state = if (Test-PayloadText $pr.review_state) { [regex]::Replace($pr.review_state, '[_\s]+', ' ').Trim().ToLowerInvariant() } else { '' }
    $role = switch ($state) { 'approved' { 'ok' } 'changes requested' { 'bad' } default { 'dim' } }
    $url = if (Test-LinkWanted $cfg) { $pr.url } else { $null }
    return @{ Name = 'pr'; Text = (Format-Link $url (Format-Icon $iconPr "#$number")); Short = $null; Role = $role; Bold = $false }
}

# With workspace.repo in the payload and the folder config at repo, the text is owner/name, followed by a
# chevron and the leaf of current_dir once the session has moved below project_dir (no project_dir counts
# as the root). The two paths are compared with forward slashes turned into backslashes, trailing
# separators trimmed and case ignored, since the payload can spell the same directory either way. Short
# is the name alone. Without a repo, with either field not a string or blank, or in leaf mode, it is the
# leaf of current_dir as it always was, with no Short form. No current_dir means no segment.
function Get-FolderSegment($d, $cfg) {
    $dir = [string] $d.workspace.current_dir
    if (-not $dir) { return $null }
    # Every piece of text this segment draws comes from outside it - a directory name, a repo owner -
    # and each one is stripped of its Format characters, so none of them can reorder the rest of the line.
    $leaf = Format-PayloadText (Split-Path $dir -Leaf)
    # The link goes round the finished text, glyph included, in both shapes below and round the Short
    # form as well, so a narrow line keeps the link it sheds the detail from. $null here, which is what
    # a path with no URL and a config with links off both give, leaves Format-Link returning its text
    # unchanged: the segment is then byte for byte what it was before this existed.
    $link = if (Test-LinkWanted $cfg) { Get-FolderUrl $dir } else { $null }
    $owner = Get-PayloadText $d.workspace.repo.owner
    $name = Get-PayloadText $d.workspace.repo.name
    if ($cfg.Folder -eq 'leaf' -or $null -eq $owner -or $null -eq $name) {
        return @{ Name = 'folder'; Text = (Format-Link $link (Format-Icon $iconFolder $leaf)); Short = $null; Role = 'folder'; Bold = $false }
    }
    $root = [string] $d.workspace.project_dir
    $here = ($dir -replace '/', '\').TrimEnd('\')
    $there = ($root -replace '/', '\').TrimEnd('\')
    $text = "$owner/$name"
    if ($root -and $here -ne $there) { $text += ' ' + (Format-Icon $iconChevron $leaf) }
    return @{ Name = 'folder'; Text = (Format-Link $link (Format-Icon $iconFolder $text)); Short = (Format-Link $link (Format-Icon $iconFolder $name)); Role = 'folder'; Bold = $false }
}

# A payload value as a count, or $null when it is not one: a whole number that fits an Int32. ConvertFrom-Json
# hands counts over as Int64; booleans, strings, fractions and out-of-range values are not counts.
# Test-PayloadDirty and Get-PayloadCount share this one rule so the pencil and the counts can never
# disagree about what a value means.
function Get-PayloadNumber($v) {
    $d = Get-FiniteNumber $v
    if ($null -eq $d -or $d -ne [math]::Floor($d)) { return $null }
    if ($d -gt [int]::MaxValue -or $d -lt [int]::MinValue) { return $null }
    return [int] $d
}

# The two families of invisible character a rendered value may not carry, and the two different answers
# to them. Cc, the C0 range, DEL and the C1 range, is an escape: U+001B, and U+009B, U+009C and U+009D
# which are CSI, ST and OSC in their 8-bit forms. A value carrying one is refused outright, because half
# an escape sequence is not a name and its presence is evidence the value is hostile rather than
# careless. Cf, the Unicode Format category, is a right-to-left override, a directional isolate, a
# zero-width joiner or a byte order mark: none of them breaks the escape syntax and ConvertTo-Json emits
# them raw, but each one reorders or hides the rest of the line, which is exactly the reasoning
# Get-IconRefusedCategory already applies to an icon code point. Those are stripped rather than refused,
# because one stray override in a branch name - and git permits one in a ref name - should cost the
# character, not the segment that says which branch the session is on. Format-PayloadText takes them
# out; Test-PayloadText answers whether anything visible is left once they are gone, so a value that is
# nothing but overrides is not text and a caller with a fallback list moves on to the next field.
# Numbers, arrays, objects, nulls and blank strings are not text either.
function Format-PayloadText([string] $Text) {
    return [regex]::Replace($Text, '\p{Cf}', '')
}

function Test-PayloadText($v) {
    return ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v) -and $v -notmatch '\p{Cc}' -and
            -not [string]::IsNullOrWhiteSpace((Format-PayloadText $v)))
}

# Test-PayloadText then Format-PayloadText, folded into the one call every caller that wants "the text,
# or nothing" was already writing by hand: the pair is retyped at every payload name in this script -
# the branch name, the repo owner and name, the worktree name and path leaf, the four badge fields, the
# model name, a cached branch record - and a caller that wrote the pair with two different values by
# mistake (guard one field, format another) would not be caught by anything. One call cannot make that
# mistake. Returns the stripped text, or $null for anything Test-PayloadText refuses - a caller that
# wants a fallback other than omitting the field writes `(Get-PayloadText $v) ?? $fallback`, the same
# shape Get-FiniteNumber's callers already use for a numeric fallback.
function Get-PayloadText($v) {
    if (-not (Test-PayloadText $v)) { return $null }
    return Format-PayloadText ([string] $v)
}

# Dirty flag from a payload git.status value: "clean"/other string, or an object of counts/booleans.
function Test-PayloadDirty($status) {
    if ($status -is [string]) { return [bool] ($status -and $status -ne 'clean') }
    if (-not $status) { return $false }
    foreach ($p in $status.PSObject.Properties) {
        $v = $p.Value
        $n = Get-PayloadNumber $v
        if (($null -ne $n -and $n -gt 0) -or ($v -is [bool] -and $v)) { return $true }
    }
    return $false
}

# File counts from a payload git.status object: the named properties staged, modified, untracked and
# conflicts, each 0 when missing or not a positive number. A string status ("clean", "modified") or
# nothing gives four zeros.
function Get-PayloadCount($status) {
    $counts = @{ Staged = 0; Modified = 0; Untracked = 0; Conflicts = 0 }
    if ($null -eq $status -or $status -is [string]) { return $counts }
    foreach ($key in @($counts.Keys)) {
        $n = Get-PayloadNumber $status.($key.ToLowerInvariant())
        if ($null -ne $n -and $n -gt 0) { $counts[$key] = $n }
    }
    return $counts
}

# The branch record from a payload git object, in the shape Read-PorcelainStatus returns, so the segment
# builder reads one record whichever source filled it. Ahead and Behind are always 0 here: the payload
# carries no upstream data. $null when the object names no branch, which means "no branch", not "go
# and look".
function Read-PayloadStatus($git) {
    # Stripped rather than refused: a name that is nothing but Format characters leaves no branch to
    # put on the line, but one carrying a stray override keeps the rest of its text.
    $branch = Format-PayloadText "$($git.branch)"
    if (-not $branch) { return $null }
    $info = Get-PayloadCount $git.status
    $info.Branch = $branch
    $info.Dirty = Test-PayloadDirty $git.status
    $info.Ahead = 0
    $info.Behind = 0
    return $info
}

# The name of the worktree the session is in, for the badge inside the branch segment. Three answers:
# the name, when worktree.name is text; the empty string, meaning "in a worktree, with nothing to call
# it", which draws the glyph on its own; and $null, meaning the session is not in a worktree at all and
# there is no badge. worktree.name is the field to use when Claude Code sends one, whatever
# workspace.git_worktree says, because a payload that names a worktree is in one. Without a usable name
# the boolean is the signal, and only a real boolean: a "true" string or a 1 is a payload that does not
# mean what this reads, so it gets no badge. Then the last segment of worktree.path stands in, taken
# after the separators are folded and any trailing one is dropped, so C:\src\wt-x\ and /home/j/wt-x
# both give wt-x. Both fields go through Test-PayloadText, the one guard the branch name and the repo
# owner and name already pass: a worktree directory is named by whoever made the repository, not by the
# person at the keyboard, and a name carrying an escape would recolour or break the rest of the line.
# Whatever that guard refuses, this refuses with it, rather than keeping a second rule of its own that
# could fall behind. Whatever that guard strips, this strips with it: the name and the path leaf are
# rendered text, so they go through Format-PayloadText the way the branch name and the repo owner do,
# and a right-to-left override in a worktree directory costs the character rather than the badge. That
# leaves the three answers where they were. A name with nothing visible left in it is not a name, so it
# falls through this chain rather than becoming a fourth answer; a path leaf with nothing left lands on
# the empty string, which is already what "in a worktree, with nothing to call it" means. Nothing here
# starts a process or touches the disk - the payload is the only source, so a render costs no more.
function Get-WorktreeName($d) {
    $wt = $d.worktree
    $name = Get-PayloadText $wt.name
    if ($null -ne $name) { return $name.Trim() }
    if ($d.workspace.git_worktree -isnot [bool] -or -not $d.workspace.git_worktree) { return $null }
    # Test-PayloadText gates $wt.path itself, but the text formatted below is the leaf substring of it,
    # not the path - Get-PayloadText's own return value is not what is wanted here, only its answer to
    # "is there anything usable in $wt.path at all".
    if ($null -ne (Get-PayloadText $wt.path)) {
        # The leaf is taken from the path as it arrived and stripped afterwards, not the other way
        # round: stripping first would turn C:\src\<override> into C:\src\ and then call the worktree
        # "src", naming the parent of a directory whose own name is invisible.
        $path = ("$($wt.path)" -replace '/', '\').TrimEnd('\')
        $leaf = Format-PayloadText $path.Substring($path.LastIndexOf('\') + 1)
        if ($leaf) { return $leaf }
    }
    return ''
}

# Branch from the payload's git object when present; otherwise from git status in current_dir, through
# the probe cache, which is handed no directory when the config turns it off and does the rest of the
# deciding itself. Either way the record has the same keys. Ahead/behind counts only exist on the git
# path; the file counts come from either source. All of them render dim between the name and the
# pencil, arrows first, then +staged ~modified ?untracked, then the conflict glyph in the removed role -
# a true red on the light warn block, a warm apricot on a dark one, for the reason given over
# Get-Palette. A session in
# a git worktree gets the fork glyph and the worktree's name in front of the counts, from the payload
# rather than from git. Short is icon, name and pencil, so a wide line sheds the badge and the counts
# before it sheds whole segments. Zero counts render nothing, and a session outside a worktree gets no
# badge, so an ordinary clean checkout is the same text as before.
function Get-BranchSegment($d, $cfg) {
    $info = if ($null -ne $d.git) { Read-PayloadStatus $d.git } else {
        $cacheDir = if ($cfg.Git.Cache) { Get-GitCacheDir } else { $null }
        Get-CachedGitBranch $d.workspace.current_dir $cfg.Git.TimeoutMs $cacheDir $cfg.Git.CacheSeconds
    }
    if (-not $info) { return $null }
    $isMain = $info.Branch -in @('main', 'master')
    $icon = if ($isMain) { $iconHome } else { $iconBranch }
    $role = if ($info.Dirty) { 'warn' } else { 'branch' }
    $name = Format-Icon $icon $info.Branch
    # The worktree badge, when the session is in one: the fork glyph and the name, straight after the
    # branch name, so the two halves of "which checkout is this" read together and the counts and the
    # pencil keep their places behind them. It is not in Short, so a narrow line sheds it with the
    # counts, and it is not in the role either: a worktree is never the reason a colour changes.
    $worktree = Get-WorktreeName $d
    $badge = if ($null -eq $worktree) { '' } elseif ($worktree) { ' ' + (Format-Icon $iconWorktree $worktree) } else { " $iconWorktree" }
    $counts = ''
    # Record key, prefix and inline colour role for each count, in the order they render.
    foreach ($row in @(@('Ahead', $iconAhead, 'track'), @('Behind', $iconBehind, 'track'), @('Staged', '+', 'track'),
                       @('Modified', '~', 'track'), @('Untracked', '?', 'track'), @('Conflicts', $iconConflict, 'removed'))) {
        $n = $info[$row[0]]
        if ($n -gt 0) { $counts += ' ' + (Format-Inline $row[2] "$($row[1])$n" $role $cfg.Style $cfg.Palette 'branch' $cfg.Tint) }
    }
    $pencil = if ($info.Dirty) { " $iconDirty" } else { '' }
    # The link goes round each finished string whole, so the badge, the counts and their inline colour
    # codes keep the places they were built in; OSC 8 carries no colour state of its own, so wrapping
    # text that already has SGR codes in it changes nothing about how it draws, and Get-VisibleWidth
    # strips the wrapper before it measures. No link, or links off, leaves both strings as they were.
    $link = if (Test-LinkWanted $cfg) { Get-BranchUrl $d $info.Branch } else { $null }
    return @{ Name = 'branch'; Text = (Format-Link $link "$name$badge$counts$pencil"); Short = (Format-Link $link "$name$pencil"); Role = $role; Bold = $false }
}

# ---- Build, lay out, fit, print ----

# THE FIRST THING THIS SCRIPT EVER WRITES, and the only write that is not a line. One site, above every
# path that prints and above the one that prints nothing, so the taskbar is told the truth on every
# render there is: the fallback below, the zero-segment stand-in, the ordinary lines, and the render
# that ends with no line at all.
#
# -NoNewline rather than a Write-Host of its own is the whole trick. The bytes are identical to gluing
# the sequence onto the front of the first line - "SEQ" then "line" then one newline - so a layout-one
# render is still one line and the matrix's "layout allows 1" still holds, and a render with no line
# writes the sequence and no newline at all, which leaves the cursor where it was and shows nothing.
# Prefixing the first line instead would have needed the same string threaded through three print sites,
# one of which does not exist on the empty render; this is one variable and one write.
#
# THE EMPTY RENDER GETS THE SEQUENCE TOO, deliberately. The argument for skipping it is that a taskbar
# bar with no status line under it is a bar with nothing explaining it. The argument against skipping is
# stronger: the sequence is terminal state that outlives the process, so a render that stays silent
# leaves the LAST render's bar lit, and that is a figure from a payload that is no longer on screen.
# An honest bar over an empty line beats a stale one, and a config that prints nothing has usually
# asked for the taskbar to be the whole display.
#
# It goes out before the payload check below, so a payload that will not parse still clears the bar
# rather than freezing it. Nothing above this line prints, so nothing can get in front of it.
#
# AND IT MUST STAY OUTSIDE THE LINE, not merely at the front of it. The folder, branch and pr segments
# each carry OSC 8 hyperlink wrappers, and folder and branch emit one in Text and another in Short, so
# a single line can hold six of them. This sequence written between an `e]8;;url`e\ and its closer would
# sit inside a hyperlink's text run, where a terminal that understands OSC 8 has to decide what to do
# with a nested command string. Writing it here, before any line exists, is what rules that out: it is
# never inside anything. A future reader who wants to prepend it to a line instead has to answer that
# question first.
$taskbar = Get-TaskbarSequence $d $cfg
if ($taskbar) { Write-Host $taskbar -NoNewline }

# A payload that is not JSON gets the fallback line. It is printed here rather than where the payload was
# read so that it carries the config's glyph overrides and the $modelWanted toggle, neither of which is
# settled any earlier. It honours the config like every other line: only the PROJECT overlay is missing
# on this path, because a payload that will not parse names no project directory, and the user file - or
# the file -Config named - was read and merged over the defaults well before this point. A config file
# that could not be parsed at all leaves those defaults, which have model on and listed, so the case this
# line exists for, saying something when nothing else can be said, is carried by the defaults rather than
# by printing over a user who asked for no model segment.
# It sits here, at the head of the print section and beside the zero-segment stand-in it is the twin of,
# rather than up beside $modelWanted: everything between the two is function definitions, so the move
# costs nothing, and the two lines that have to answer the same config the same way can now be read
# together.
# It carries the style too, because the glyph it prints comes from the same set every builder reads: the
# ascii style leaves the model stand-in empty, so this line is the bare word `claude` with no space in
# front of it, which is what Format-Icon is here for.
# The stand-in resolves through the same tint chooser as a real model block. That keeps role tint on
# the model role and lets segment tint use the model segment's resting colour even when no segment was
# built, whether the payload was unusable or every configured segment was switched off.
$standInSgr = (Get-TintColour (Get-Palette $cfg.Palette) 'model' 'model' $cfg.Tint $cfg.Palette).Sgr
if (-not $payloadOk) {
    if ($modelWanted) { Write-Host (C $standInSgr (Format-Icon $iconModel 'claude')) }
    exit 0
}

# The state this session's last render left behind, read before the segments are built because the cost
# segment's per-turn delta is the difference from the total it holds. It is the only read of the file in
# a render: the write at the foot of the script merges over this record rather than opening it again.
# $null covers every way there is nothing to compare against - state turned off, no session id, no file
# yet, an unreadable one - and every segment renders exactly as it did before deltas existed. The read
# does not create the directory; only the write does, so a render that writes nothing still leaves none.
# It sits below the bad-payload line rather than beside $lineSets, because a payload that will not parse
# names no session to read state for; every render that gets this far reads once, including one that
# goes on to print nothing at all.
$sessionId = [string] $d.session_id
$state = if ($cfg.State -and $sessionId) { Read-SessionState $sessionId } else { $null }

# A segment that is toggled off, or that no line lists, is not built at all, so an order without branch
# never runs the git probe. $lineSets and $listed are settled above, before the bad-payload line.
$segments = [System.Collections.Generic.List[hashtable]]::new()
foreach ($rec in Get-SegmentRegistry) {
    if (-not $cfg.Segments[$rec.Name] -or -not $listed[$rec.Name]) { continue }
    $seg = & $rec.Build $d $cfg $state
    if ($seg) { $segments.Add($seg) }
}
# Every enabled and listed builder returned nothing. The stand-in line goes out under $modelWanted, the
# same rule the bad-payload line above uses, and belongs on screen only where a model segment was
# allowed. Get-ModelSegment itself never returns $null any more (an unusable or absent
# model.display_name falls back to the "claude" word this line also prints), so the case this is
# actually for is narrower than it once was: model turned off, or left out of the order or every row,
# where the builder above is never called at all and $segments can still come back empty. A config
# that turns model off, or whose order leaves it out, asked for a line with no model on it; nothing
# printed is that answer, the same answer the loop below already gives when every line shrinks away to
# nothing.
#
# No exit here, deliberately. A payload that parsed carries a session id and its cost, token and rate
# figures whatever the config chose to put on screen, and the state file is where the next render reads
# them back from, so a display choice must not throw the sample away or skip the sweep. Falling through
# is silent with no segments: Get-FittedLine returns $null for an empty line and the loop prints nothing.
if ($segments.Count -eq 0 -and $modelWanted) { Write-Host (C $standInSgr (Format-Icon $iconModel 'claude')) }

# Claude Code sets COLUMNS before running the script. Leave one column free to avoid the pending-wrap glitch.
$width = $null
$cols = 0
if ([int]::TryParse([string] $env:COLUMNS, [ref] $cols) -and $cols -gt 0) { $width = $cols - 1 }

# A line that fits down to nothing is not printed. With model toggled off and a very narrow terminal
# that can mean no output at all, which is what the user asked for.
#
# The right group belongs to the FIRST line set and to no other: layout one has only one line, and in
# layout two the second row renders exactly as it did before. Emptied after the first pass rather than
# tested against an index, so a row that renders nothing still spends the group - the group is row one's
# whether or not row one prints - and so this stays one added variable in a loop another branch is also
# editing.
$rightGroup = [string[]] $cfg.Right
foreach ($names in $lineSets) {
    $onLine = foreach ($n in $names) { foreach ($s in $segments) { if ($s.Name -eq $n) { $s } } }
    $text = Get-FittedLine @($onLine) $cfg.Style $width -Right $rightGroup -Palette $cfg.Palette -Tint $cfg.Tint
    $rightGroup = $null
    if ($text) { Write-Host $text }
}

# The merge and the write sit after the last Write-Host, so neither is in front of the visible line. The
# read is the one part that had to move above it, because the cost segment's delta is built from it; it
# is still one read and one write per render, because what is merged here is the record already read.
if ($cfg.State -and $sessionId) {
    Write-SessionState $sessionId (Merge-SessionState $state $d ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
}
