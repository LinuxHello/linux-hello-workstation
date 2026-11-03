Spike 0013: upstream licences fit C2 and C3

libwebauthn is LGPL-2.1-or-later, KeePassXC GPL-2.0 or GPL-3.0,
fprintd GPL-2.0-or-later, Howdy MIT with public-domain face models;
credentialsd LGPL-3.0-only (spike 0005). Linked libraries are LGPL;
GPL components stay across a process boundary.

deny.toml and the dependency-review workflow now also allow
LGPL-3.0-only and LGPL-2.1-or-later, so credentialsd and libwebauthn
can be added. No GPL licence is allowed. The architecture note's
licence line links the spike.

Closes #13

Assisted-by: Claude Code (claude-opus-5-5)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
