# Security

This package reads archives that come from outside: a file a user picked, a
file another application handed over. An archive that gets past the reader's
checks — a name that escapes the unpack directory, a length that allocates
more than the archive could hold, a payload that skips its checksum, an
inflation that passes the caller's `RMDocReadLimits` or produces more than
its entry declared, an entry the caller declined that is inflated anyway —
is a vulnerability, and is worth reporting privately rather than in an issue.

Report it through GitHub's private vulnerability reporting: the **Security**
tab of this repository, then **Report a vulnerability**. The archive that
shows it, or the bytes to build one, is the most useful thing to attach.

Fixes go into the latest release; there are no maintained older branches.
