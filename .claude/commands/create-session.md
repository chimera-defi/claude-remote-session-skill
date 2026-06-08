Create a persistent Claude remote session using the gstack-session-spawn skill.

If the user provided a project name or folder, use that. Otherwise ask: "Which project/folder should the session run in?"

Then follow the full recipe from the gstack-session-spawn skill:

1. Set FOLDERNAME to the project name (use the folder name exactly as it appears in /home/agents/workspace/).
2. Run `date +%Y%m%d` to get today's date.
3. Derive: SESSION=agenthost_${FOLDERNAME}-${DATE}, REMOTE_NAME=agenthost-${FOLDERNAME}-${DATE}, WORKDIR=/home/agents/workspace/${FOLDERNAME}
4. Create the start script at ~/.local/bin/${REMOTE_NAME}-start.sh (include log_start logging, sentinel file, smart backoff).
5. Create the systemd service at ~/.config/systemd/user/${REMOTE_NAME}.service
6. Run: systemctl --user daemon-reload && systemctl --user enable --now ${REMOTE_NAME}.service
7. Pre-accept trust for WORKDIR in ~/.claude.json
8. Verify with: tmux list-sessions | grep agenthost_${FOLDERNAME}

After success, tell the user:
- The remote-control name to connect with (agenthost-${FOLDERNAME}-${DATE})
- That it appears in Claude Code app → Remote sessions
- Commit the scripts to chimera-defi/Etc-mono-repo under scripts/agenthost/

Full recipe is in ~/.claude/skills/gstack-session-spawn/SKILL.md
