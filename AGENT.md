# AGENT.md - Amp.el Development Guide

## Commands
- **Development**: Load with `(load-file "amp.el")`, start server with `M-x amp-start`
- **Testing**: Manual testing with `amp --ide` CLI integration
- **Debug**: View `*amp-log*` buffer to see WebSocket communication, selection changes, errors
- **Status**: Check connections with `M-x amp-status`

## Architecture
- **Single file**: All code in amp.el (~550 lines) - Emacs Lisp package for Amp IDE integration
- **Core protocol**: WebSocket server implementing Amp's IDE protocol (same as amp.nvim)
- **Lockfile discovery**: Writes JSON lockfiles to `~/.local/share/amp/ide/{port}.json` for Amp CLI
- **Features**: 
  - Selection tracking (cursor + visual regions) via `post-command-hook`
  - Visible files tracking via window hooks
  - Diagnostics integration with Flymake
  - IDE protocol handlers: `ping`, `authenticate`, `readFile`, `editFile`
  - Message sending: `userSentMessage`, `appendToPrompt`
  - Automatic cleanup on Emacs exit via `kill-emacs-hook`

## Testing via emacsclient

The implementation can be tested and debugged using `emacsclient`:

```bash
# Load the file
emacsclient --eval "(load-file \"$(pwd)/amp.el\")"

# Start the server
emacsclient --eval "(amp-start)"

# Check status
emacsclient --eval "(amp-status)"

# View logs
emacsclient --eval "(with-current-buffer (get-buffer \"*amp-log*\") (buffer-substring-no-properties (max 1 (- (point-max) 1000)) (point-max)))"

# Test selection tracking
emacsclient --eval "(amp--get-current-selection)"

# Stop and restart (for reloading changes)
emacsclient --eval "(progn (when amp--server (amp-stop)) (load-file \"$(pwd)/amp.el\") (amp-start))"
```

## References
- **Amp source**: Main Amp codebase at `/home/keegan/src/github.com/sourcegraph/amp`
- **IDE protocol**: Client IDE code at `/home/keegan/src/github.com/sourcegraph/amp/core/src/ide/`
- **Implementation reference**: Ported from https://github.com/sourcegraph/amp.nvim
- **Original inspiration**: claude-code-ide.el at `/home/keegan/src/github.com/manzaltu/claude-code-ide.el`
