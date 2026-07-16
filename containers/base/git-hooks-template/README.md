# NEUTRAL git hooks template mounted in the Claude container.
#
# core.hooksPath points here (see containers/base/entrypoint.sh) so that
# hooks created/modified by the agent are NOT persisted on the host: this closes
# a sandbox escape path (a malicious hook would execute on the user's next
# `git commit` on their machine).
#
# Keep this directory empty (no active hooks).
