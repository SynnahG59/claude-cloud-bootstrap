#!/bin/bash
# Prueft in einer neuen Sitzung der Master-Umgebung, ob der globale
# Werkzeugkasten (Phase 1) und das Projektgedaechtnis (Phase 2) automatisch
# eingerichtet wurden. Aendert nichts und gibt keine Werte von Variablen aus
# (nur ja/nein).   Aufruf: bash /opt/claude-cloud-bootstrap/verify.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

PASS=0; FAIL=0
ok()  { printf '  [x] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [ ] %s\n' "$*"; FAIL=$((FAIL + 1)); }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

SETTINGS="$HOME/.claude/settings.json"
# Ein Hook-Kommando der Art $1 (z. B. "SessionStart") mit Text $2 vorhanden?
has_hook() { jq -e --arg ev "$1" --arg s "$2" \
  '[.hooks[$ev][]?.hooks[]?.command | select(contains($s))] | length > 0' "$SETTINGS"; }
cm_get() { jq -r --arg k "$1" '.[$k] // empty' "$MEM_SETTINGS" 2>/dev/null; }
PORT="${CLAUDE_MEM_WORKER_PORT:-$((37700 + $(id -u) % 100))}"
NAME="$(project_name)"

echo "Umgebung"
chk "Cloud-Sitzung (CLAUDE_CODE_REMOTE=true)" test "${CLAUDE_CODE_REMOTE:-}" = "true"
chk "GLOBAL_GH_TOKEN gesetzt"                  test -n "${GLOBAL_GH_TOKEN:-}"
if [ -n "$NAME" ]; then ok "Projekt erkannt: $NAME"; else bad "Projekt erkannt (Git-Remote origin im Projektordner)"; fi

echo "Phase 1: Setup-Script (vor dem Start von Claude Code)"
chk "Bootstrap-Repo geladen ($KIT_DIR)"        test -d "$KIT_DIR/.git"
chk "install.sh ist gelaufen ($MARKER_FILE)"   test -f "$MARKER_FILE"
[ -f "$MARKER_FILE" ] && sed 's/^/      /' "$MARKER_FILE"
chk "Setup-Log ohne FEHLER/ABBRUCH" bash -c "! grep -qE 'FEHLER|ABBRUCH' '$GLOBAL_LOG'"
grep -E 'gesetzt:|WARN|FEHLER|ABBRUCH' "$GLOBAL_LOG" 2>/dev/null | sed 's/^/      /'

echo "Werkzeugkasten"
PLUGINS="$(claude plugin list 2>/dev/null || true)"
chk "context-mode Plugin"                    grep -q 'context-mode' <<<"$PLUGINS"
chk "context-mode $CONTEXT_MODE_VERSION (npm)" bash -c "npm ls -g --depth 0 'context-mode@$CONTEXT_MODE_VERSION'"
chk "claude-mem Plugin"                      grep -q 'claude-mem'   <<<"$PLUGINS"
chk "claude-mem $CLAUDE_MEM_VERSION (Plugin-Ordner)" cm_plugin_dir
chk "global-kit vorhanden"                   test -f "$HOME/.claude/skills/global-kit/.claude-plugin/plugin.json"
chk "globale CLAUDE.md"                      grep -q 'claude-cloud-bootstrap:managed' "$HOME/.claude/CLAUDE.md"

echo "Globale Einstellungen ($SETTINGS)"
chk "settings.json gueltiges JSON"               jq -e . "$SETTINGS"
chk "SessionStart -> hooks/session-start.sh"     has_hook SessionStart "$KIT_DIR/hooks/session-start.sh"
chk "Stop -> mem-sync/mem-push.sh"               has_hook Stop "$KIT_DIR/mem-sync/mem-push.sh"
chk "SessionEnd -> mem-sync/mem-push.sh --force" has_hook SessionEnd "$KIT_DIR/mem-sync/mem-push.sh --force"
chk "Berechtigungen (allow/deny) gesetzt"        jq -e '(.permissions.allow | length > 0) and (.permissions.deny | length > 0)' "$SETTINGS"

echo "Claude-Mem-Einstellungen ($MEM_SETTINGS)"
chk "Projektnamen aus Git-Remote"            test "$(cm_get CLAUDE_MEM_PROJECT_NAME_SOURCE)" = "git-remote"
if [ -f "$MEM_STATE" ]; then
  chk "Autostart nach erfolgreichem Pull eingeschaltet" test "$(cm_get CLAUDE_MEM_WORKER_AUTOSTART)" = "true"
else
  chk "Autostart aus (kein erfolgreicher Pull)"        test "$(cm_get CLAUDE_MEM_WORKER_AUTOSTART)" = "false"
fi

echo "Phase 2: Projektgedaechtnis (SessionStart, mit Token)"
chk "mem-pull erfolgreich (.sync-ok, sonst keine Sicherung)" test -f "$MEM_STATE"
if [ -f "$MEM_STATE" ]; then
  sed -n 's/^\(name\|key\|mode\)=/      \1=/p' "$MEM_STATE"
  chk "Gedaechtnis gehoert zum geoeffneten Projekt" test "$(sed -n 's/^name=//p' "$MEM_STATE")" = "$NAME"
  chk "Claude-Mem-Projektname fest zugeordnet ($NAME)" bash -c '
    jq -e --arg n "$1" --arg d "$2" "(.CLAUDE_MEM_PROJECT_ENVIRONMENTS // \"[]\") | fromjson
      | any(.[]; .name == \$n and (.patterns | index(\$d)))" "$0"' "$MEM_SETTINGS" "$NAME" "$(project_dir)"
  chk "Sync-Modus normal (kein Konflikt)"          grep -qx 'mode=normal' "$MEM_STATE"
fi
chk "Worker antwortet (Port $PORT)" curl -fsS -m 3 "http://127.0.0.1:$PORT/api/health"
if [ -f "$MEM_DATA_DIR/$MEM_DB_NAME" ]; then ok "lokale DB vorhanden"; else bad "lokale DB vorhanden (entsteht evtl. erst nach dem ersten Turn)"; fi
grep -q 'Startkontext nachgeladen' "$MEM_LOG" 2>/dev/null && ok "Startkontext nachgeladen" || bad "Startkontext nachgeladen"
[ -f "$MEM_LOG" ] && tail -n 8 "$MEM_LOG" | sed 's/^/      /'

echo
echo "Ergebnis: $PASS ok, $FAIL offen"
echo "In der Sitzung zusaetzlich pruefen: /plugin, /mcp, /memory und /context-mode:ctx-doctor"
