Source: https://github.com/eembc/coremark

Commit: b56889a7bd9d5624fbeff2a73ba69878e6a9c146

CoreMark 1.0 algorithm files and coremark.h are kept byte-for-byte from this
commit's canonical Git blobs (LF line endings). All six files match the official
coremark.md5. The newer main tip had a stale header MD5 entry; this immediately
preceding mainline commit was selected instead. The original Apache-2.0 license
and coremark.md5 are included.
The local adaptation is in firmware/coremark_port/core_portme.c/.h only.
The board drivers, startup and required integer helpers live outside this folder.

The port selects the upstream HAS_FLOAT=0 path. Upstream integer seconds/rates
are coarse display values. For precise reporting use the raw 64-bit cycle count
and actual iterations in CM_RESULT, with a run lasting at least ten seconds and
successful standard CRC validation. Short simulated runs are not hardware scores.
