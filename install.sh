#!/bin/bash
# Phase 1: richtet den globalen Werkzeugkasten ein, BEVOR Claude Code startet.
# Wird nur von bootstrap.sh aufgerufen (Setup-Script der Master-Umgebung).
# Braucht keinen Token: nur npm und dieses oeffentliche Repo.
# Idempotent: mehrfaches Ausfuehren schadet nicht.
# Bricht nie hart ab: jeder Schritt meldet WARN und der naechste laeuft weiter.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

# --- Schutz -------------------------------------------------------------
# Nur ueber bootstrap.sh (setzt KIT_BOOTSTRAP=1), nie versehentlich von Hand
# oder auf einem anderen Rechner.
if [ "${KIT_BOOTSTRAP:-}" != "1" ]; then
  log "ABBRUCH: install.sh laeuft nur ueber bootstrap.sh (KIT_BOOTSTRAP=1 fehlt)." >&2
  exit 1
fi
if [ "${GLOBAL_KIT_DISABLE:-0}" = "1" ]; then
  log "GLOBAL_KIT_DISABLE=1, nichts zu tun"
  exit 0
fi

WARNINGS=0
step() { log "== $*"; }
warn() { log "WARN: $*"; WARNINGS=$((WARNINGS + 1)); }

mkdir -p "$HOME/.claude/skills"

# --- 0) Voraussetzungen -----------------------------------------------
step "Voraussetzungen"
for bin in node npm npx git jq python3 claude flock; do
  command -v "$bin" >/dev/null 2>&1 || warn "$bin fehlt"
done

# --- 1) Context-mode ----------------------------------------------------
# Das npm-Paket enthaelt selbst einen Plugin-Marketplace (.claude-plugin/).
# Er wird als lokaler Marketplace eingetragen: volles Plugin mit Hooks,
# MCP-Tools und Slash-Commands, ohne Abhaengigkeit von GitHub.
step "Context-mode $CONTEXT_MODE_VERSION"
if npm install -g "context-mode@$CONTEXT_MODE_VERSION" --no-fund --no-audit; then
  CTX_DIR="$(npm root -g)/context-mode"
  claude plugin marketplace add "$CTX_DIR" --scope user \
    || warn "context-mode: Marketplace nicht eingetragen (evtl. schon vorhanden)"
  claude plugin install context-mode@context-mode --scope user \
    || warn "context-mode: Plugin-Installation fehlgeschlagen"
else
  warn "npm install context-mode@$CONTEXT_MODE_VERSION fehlgeschlagen"
fi

# --- 2) Claude-Mem ------------------------------------------------------
# Lokal, ohne Hosted-Dienst, ohne Rueckfragen. Das Plugin muss VOR dem Start
# installiert sein. Der Worker startet aber NICHT von selbst
# (CLAUDE_MEM_WORKER_AUTOSTART=false): erst der SessionStart-Hook laedt das
# Gedaechtnis des Projekts und startet ihn danach. Projektnamen kommen aus der
# Git-Remote-URL ("owner/repo"), damit sie eindeutig sind.
step "Claude-Mem $CLAUDE_MEM_VERSION"
CLAUDE_MEM_ONLINE_OPTIN=false CLAUDE_MEM_NO_BANNER=1 \
  npx -y "claude-mem@$CLAUDE_MEM_VERSION" install --ide claude-code --provider claude --no-auto-start \
  || warn "claude-mem install fehlgeschlagen"
cm_setting CLAUDE_MEM_WORKER_AUTOSTART false     || warn "Claude-Mem: Autostart nicht abgeschaltet"
cm_setting CLAUDE_MEM_PROJECT_NAME_SOURCE git-remote || warn "Claude-Mem: Projektnamen-Quelle nicht gesetzt"
cm_plugin_dir >/dev/null || warn "Claude-Mem: Plugin-Ordner fuer $CLAUDE_MEM_VERSION nicht gefunden"

# --- 3) Eigenes Plugin global-kit (allgemeine MCPs + Skills) ------------
# Liegt als skills-dir-Plugin unter ~/.claude/skills/global-kit und wird von
# Claude Code beim Start automatisch geladen (global-kit@skills-dir).
step "global-kit"
rm -rf "$HOME/.claude/skills/global-kit"
cp -a "$HERE/global-kit" "$HOME/.claude/skills/global-kit" || warn "global-kit nicht kopiert"

# --- 4) Globale CLAUDE.md -------------------------------------------------
# Allgemeine Arbeitsregeln fuer alle Projekte. Projektwissen steht in der
# CLAUDE.md des jeweiligen Projekt-Repos. Eine fremde Datei wird nie ersetzt.
step "globale CLAUDE.md"
G_MD="$HOME/.claude/CLAUDE.md"
if [ ! -e "$G_MD" ] || grep -q 'claude-cloud-bootstrap:managed' "$G_MD"; then
  cp "$HERE/global/CLAUDE.md" "$G_MD" || warn "globale CLAUDE.md nicht kopiert"
else
  warn "~/.claude/CLAUDE.md existiert und stammt nicht von hier, bleibt unveraendert"
fi

# --- 5) ~/.claude/settings.json zusammenfuehren ------------------------
# Globale Hooks, Berechtigungen und Einstellungen fuer jede Sitzung. Vorhandene
# Einstellungen (z. B. enabledPlugins von claude plugin install) bleiben
# erhalten; Objekte werden rekursiv zusammengefuehrt, Listen vereinigt.
step "settings.json"
SETTINGS="$HOME/.claude/settings.json"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if jq -s --arg kit "$KIT_DIR" '
    def merge($a; $b):
      reduce ($b | keys_unsorted[]) as $k ($a;
        .[$k] = (if ($a[$k] | type) == "object" and ($b[$k] | type) == "object" then merge($a[$k]; $b[$k])
                 elif ($a[$k] | type) == "array" and ($b[$k] | type) == "array" then ($a[$k] + $b[$k]) | unique_by(tojson)
                 else $b[$k] end));
    .[0] as $cur
    | (.[1] | walk(if type == "string" then gsub("__KIT_DIR__"; $kit) else . end)) as $tpl
    | merge($cur; $tpl)
  ' "$SETTINGS" "$HERE/settings.template.json" > "$SETTINGS.tmp"; then
  mv "$SETTINGS.tmp" "$SETTINGS"
else
  rm -f "$SETTINGS.tmp"
  warn "settings.json konnte nicht zusammengefuehrt werden (unveraendert)"
fi

# --- 6) Marker fuer verify.sh -------------------------------------------
{
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kit_commit=$(git -C "$KIT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "context_mode=$CONTEXT_MODE_VERSION"
  echo "claude_mem=$CLAUDE_MEM_VERSION"
  echo "warnings=$WARNINGS"
} > "$MARKER_FILE"

log "install.sh fertig, Warnungen: $WARNINGS"
exit 0
