#!/bin/bash
# Phase 2: SessionStart-Hook (von install.sh in ~/.claude/settings.json
# eingetragen, gilt also in jeder Sitzung, egal welches Projekt).
# Erst jetzt sind GLOBAL_GH_TOKEN und der GitHub-Proxy der Sitzung verfuegbar.
#
#   1. Gedaechtnis des aktuellen Projekts aus claude-mem-data laden (mem-pull)
#   2. nur bei Erfolg: Claude-Mem-Autostart einschalten und Worker starten
#   3. Startkontext von Claude-Mem nachladen und an Claude Code durchreichen
#      (der Kontext-Hook des Plugins lief schon, als noch kein Worker lief)
#
# Ohne erfolgreichen Pull bleibt Claude-Mem in dieser Sitzung aus: es entsteht
# keine abweichende lokale DB und es wird nichts gesichert.
# stdout enthaelt NUR die Kontext-Ausgabe von Claude-Mem (JSON), alles andere
# geht ins Protokoll /tmp/claude-mem-sync.log. Exit immer 0.

set -uo pipefail

HOOK_INPUT=""
[ -t 0 ] || HOOK_INPUT="$(cat)"

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ "${GLOBAL_KIT_DISABLE:-0}" = "1" ]   && exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

worker_healthy() {
  local port="${CLAUDE_MEM_WORKER_PORT:-$((37700 + $(id -u) % 100))}"
  curl -fsS -m 3 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1
}

CONTEXT_OUT=""
{
  exec 9>/tmp/claude-mem-pull.lock
  if ! flock -n 9; then
    log "[session-start] laeuft bereits, uebersprungen"
    exit 0
  fi

  # Fortgesetzte Sitzung im selben Container: alles laeuft schon.
  if [ -f "$MEM_STATE" ] && worker_healthy; then
    log "[session-start] Gedaechtnis und Worker schon aktiv, nichts zu tun"
    exit 0
  fi

  if [ -z "${GLOBAL_GH_TOKEN:-}" ]; then
    log "[session-start] GLOBAL_GH_TOKEN fehlt, Claude-Mem bleibt aus"
    exit 0
  fi

  if ! bash "$HERE/../mem-sync/mem-pull.sh"; then
    log "[session-start] mem-pull nicht erfolgreich, Claude-Mem bleibt in dieser Sitzung aus"
    exit 0
  fi

  # Festen, kleingeschriebenen Projektnamen fuer diesen Projektordner vorgeben,
  # bevor der Worker startet (sonst haengt der Name an der Schreibweise der
  # Remote-URL). Ohne diese Zuordnung bleibt Claude-Mem aus.
  P_NAME="$(sed -n 's/^name=//p' "$MEM_STATE" | head -n 1)"
  P_DIR="$(sed -n 's/^dir=//p' "$MEM_STATE" | head -n 1)"
  if ! cm_map_project "$P_NAME" "$P_DIR"; then
    log "[session-start] WARN Projektname konnte nicht zugeordnet werden, Claude-Mem bleibt aus"
    rm -f "$MEM_STATE"
    exit 0
  fi
  log "[session-start] Projekt $P_NAME -> $P_DIR"

  if ! cm_setting CLAUDE_MEM_WORKER_AUTOSTART true; then
    log "[session-start] WARN Autostart konnte nicht eingeschaltet werden"
    exit 0
  fi
  if ! cm_worker start </dev/null >/dev/null 2>&1 || ! worker_healthy; then
    log "[session-start] WARN Claude-Mem-Worker antwortet nicht"
    exit 0
  fi
  log "[session-start] Worker laeuft"

  # Startkontext nachladen: derselbe Befehl, den der Plugin-Hook benutzt,
  # mit der Original-Eingabe dieses Hooks.
  if CONTEXT_OUT="$(printf '%s' "$HOOK_INPUT" | cm_worker hook claude-code context 2>/dev/null)"; then
    log "[session-start] Startkontext nachgeladen (${#CONTEXT_OUT} Zeichen)"
  else
    CONTEXT_OUT=""
    log "[session-start] WARN Startkontext konnte nicht geladen werden"
  fi
} >>"$MEM_LOG" 2>&1

# Nur gueltiges JSON durchreichen, sonst nichts ausgeben.
if [ -n "$CONTEXT_OUT" ] && printf '%s' "$CONTEXT_OUT" | jq -e . >/dev/null 2>&1; then
  printf '%s\n' "$CONTEXT_OUT"
fi
exit 0
