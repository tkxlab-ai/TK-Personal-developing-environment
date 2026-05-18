#!/usr/bin/env bash
# Smart clipboard copy: strips leading/trailing whitespace and trailing newlines.
# Receives selected text from tmux copy-pipe-and-cancel via stdin.

input=$(cat)

# Remove leading and trailing whitespace (spaces, tabs, newlines)
trimmed=$(printf '%s' "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Write to clipboard
if command -v pbcopy &>/dev/null; then
    printf '%s' "$trimmed" | pbcopy
elif command -v xclip &>/dev/null; then
    printf '%s' "$trimmed" | xclip -selection clipboard
elif command -v xsel &>/dev/null; then
    printf '%s' "$trimmed" | xsel --clipboard --input
fi
