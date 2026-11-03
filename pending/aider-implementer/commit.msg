Run the implementer through Aider (ADR-0004 amendment)

Claude Code cannot be set to a context window below 100k tokens; the
local model is served with 32k and the server truncates longer
prompts, so the first implementer run lost its instructions. Aider
sends only the brief's files plus the instruction. The model only
edits code; a script runs the gates, checks that every test the brief
names exists and that nothing outside the brief changed, then commits,
pushes and opens the pull request.

Assisted-by: Claude Code (claude-opus-5-5)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
