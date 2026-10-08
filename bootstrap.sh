#!/bin/bash
# =====================================================================
#  Setup-Script der Master-Umgebung fuer Claude Code (Cloud).
#  Jede Sitzung dieser Umgebung bekommt den kompletten globalen
#  Werkzeugkasten, egal welches Projekt-Repo geoeffnet wird.
#
#  Inhalt dieser Datei 1:1 in claude.ai -> Umgebung -> Edit
#  -> "Setup script" einfuegen. Danach nie wieder anfassen: alle
#  Aenderungen passieren in diesem oeffentlichen Repo (Branch main).
#
#  Phase 1 (hier, vor dem Start von Claude Code): Plugins, MCPs, Skills,
#  globale CLAUDE.md und globale Hooks muessen jetzt schon an Ort und Stelle
#  sein, sonst laedt die Sitzung sie nicht. In dieser Phase gibt es weder
#  GLOBAL_GH_TOKEN noch den GitHub-Proxy, deshalb wird dieses Repo OHNE
#  Anmeldung geladen (es ist oeffentlich und enthaelt keine Zugangsdaten).
#
#  Phase 2 (SessionStart-Hook, mit Token): Gedaechtnis des aktuellen
#  Projekts laden, danach erst den Claude-Mem-Worker starten.
# =====================================================================

REPO_URL="https://github.com/SynnahG59/claude-cloud-bootstrap.git"
BRANCH="main"
DIR="/opt/claude-cloud-bootstrap"
LOG="/tmp/global-setup.log"

# Interne Freigabe: install.sh laeuft nur, wenn dieses Script es startet.
export KIT_BOOTSTRAP=1

yn() { if [ -n "${!1:-}" ]; then echo ja; else echo nein; fi; }

load_repo() {
  if [ -d "$DIR/.git" ] \
     && GIT_TERMINAL_PROMPT=0 git -C "$DIR" fetch --depth 1 origin "$BRANCH" \
     && git -C "$DIR" reset --hard FETCH_HEAD; then
    return 0
  fi
  rm -rf "$DIR"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$DIR"
}

{
  echo "[bootstrap] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Nur ja/nein, niemals Werte
  echo "[bootstrap] gesetzt: GLOBAL_GH_TOKEN=$(yn GLOBAL_GH_TOKEN) HTTPS_PROXY=$(yn HTTPS_PROXY)"
  if [ "${GLOBAL_KIT_DISABLE:-0}" = "1" ]; then
    echo "[bootstrap] GLOBAL_KIT_DISABLE=1, nichts zu tun"
  else
    ok=0
    for i in 1 2 3; do
      if load_repo; then ok=1; break; fi
      echo "[bootstrap] WARN: Versuch $i fehlgeschlagen"
      sleep $((i * 5))
    done
    if [ "$ok" = "1" ]; then
      bash "$DIR/install.sh"
    else
      echo "[bootstrap] FEHLER: $REPO_URL konnte nach 3 Versuchen nicht geladen werden"
    fi
  fi
  echo "[bootstrap] ende"
} >>"$LOG" 2>&1

# Die Sitzung soll immer starten, auch wenn hier etwas schiefgeht.
exit 0
