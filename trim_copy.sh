#!/usr/bin/env bash
# Smart clipboard copy:
#   - Strips leading/trailing whitespace of the WHOLE selection (not per line —
#     preserves internal indentation in multi-line code blocks).
#   - Falls back across pbcopy / xclip / xsel; reports error if none available.
# Reads selected text from tmux copy-pipe-and-cancel via stdin.

set -u

input=$(cat)

# Trim only the leading/trailing whitespace of the whole text. Internal
# indentation is preserved. awk with RS="\0" treats stdin as one record.
trimmed=$(printf '%s' "$input" | awk 'BEGIN{RS="\0"} {
    sub(/^[[:space:]]+/, "")
    sub(/[[:space:]]+$/, "")
    printf "%s", $0
}')

# Write to system clipboard, tmux paste-buffer is already filled by copy-pipe.
# If no tool available, report on stderr (tmux will surface this in copy-mode
# message bar if visible, otherwise discarded — but at least we exit non-zero).
if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$trimmed" | pbcopy
elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$trimmed" | xclip -selection clipboard
elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$trimmed" | xsel --clipboard --input
else
    printf 'trim_copy.sh: no clipboard tool found (pbcopy/xclip/xsel)\n' >&2
    exit 1
fi
