#!/bin/bash
# Laedt das Claude-Mem-Gedaechtnis des AKTUELLEN Projekts aus dem privaten
# Repo claude-mem-data nach ~/.claude-mem/. Laeuft beim Sitzungsstart ueber
# hooks/session-start.sh (Phase 2, mit GLOBAL_GH_TOKEN), BEVOR der
# Claude-Mem-Worker startet.
#
# Ablage: eine Datei pro Projekt, projects/<owner>__<repo>/claude-mem.db
# (kleingeschrieben, siehe project_name in lib/common.sh).
# Es wird nur der Ordner des aktuellen Projekts ausgecheckt (sparse).
#
# Sicherheitsregeln:
#   - Nur wenn das Laden geklappt hat, wird $MEM_STATE (.sync-ok) geschrieben.
#     Ohne sie verweigert mem-push.sh jeden Push.
#   - Gibt es VOR dem Pull schon eine lokale DB, gilt der Pull als nicht
#     erfolgreich: kein .sync-ok, keine Sicherung, lokale DB bleibt unangetastet.
#   - Ohne Git-Remote (kein eindeutiger Projektname) wird nichts synchronisiert.
#   - .sync-ok merkt sich den geladenen Stand (base). mem-push.sh ueberschreibt
#     die Projektdatei nur, solange im Repo noch genau dieser Stand liegt.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "$HERE/../lib/common.sh"

rm -f "$MEM_STATE"

NAME="$(project_name)"
KEY="$(project_key "$NAME")"
PDIR="$(project_dir)"
if [ -z "$KEY" ] || [ -z "$PDIR" ]; then
  log "mem-pull: kein eindeutiges Projekt (Git-Remote origin fehlt oder ungewoehnlich), kein Sync"
  exit 1
fi
REL="projects/$KEY"

DST="$MEM_DATA_DIR/$MEM_DB_NAME"
if [ -e "$DST" ]; then
  log "mem-pull: WARN lokale DB existiert bereits ($DST). Gedaechtnis nicht geladen, keine Sicherung in dieser Sitzung."
  exit 1
fi

# Frischer, flacher Klon ohne Dateiinhalte; Inhalte nur fuer das eigene Projekt.
rm -rf "$MEM_CHECKOUT"
if ! gh_git clone -q --depth 1 --filter=blob:none --no-checkout "$(gh_url "$MEM_REPO")" "$MEM_CHECKOUT"; then
  log "mem-pull: $MEM_REPO nicht erreichbar (Repo angelegt? Token gueltig?)"; exit 1
fi
git -C "$MEM_CHECKOUT" sparse-checkout set --cone "$REL" >/dev/null 2>&1 \
  || { log "mem-pull: sparse-checkout fehlgeschlagen"; exit 1; }

if git -C "$MEM_CHECKOUT" rev-parse -q --verify HEAD >/dev/null; then
  gh_git -C "$MEM_CHECKOUT" checkout -q "$MEM_BRANCH" \
    || { log "mem-pull: checkout fehlgeschlagen"; exit 1; }
  BASE="$(git -C "$MEM_CHECKOUT" rev-parse -q --verify "HEAD:$REL/$MEM_DB_NAME" || echo none)"
else
  # Leeres Repo (noch kein Commit): Branch entsteht beim ersten Push.
  git -C "$MEM_CHECKOUT" checkout -q -B "$MEM_BRANCH" 2>/dev/null || true
  BASE=none
  log "mem-pull: $MEM_REPO ist noch leer"
fi

mkdir -p "$MEM_DATA_DIR"
SRC="$MEM_CHECKOUT/$REL/$MEM_DB_NAME"
if [ -f "$SRC" ]; then
  # Kopie erst unter Temp-Namen, dann ohne Ueberschreiben an ihren Platz.
  if ! cp "$SRC" "$DST.pull-tmp" || ! mv -n "$DST.pull-tmp" "$DST" || [ -e "$DST.pull-tmp" ]; then
    rm -f "$DST.pull-tmp"
    log "mem-pull: WARN Gedaechtnis konnte nicht geladen werden (lokale DB inzwischen vorhanden?), keine Sicherung in dieser Sitzung."
    exit 1
  fi
  log "mem-pull: Gedaechtnis von $NAME geladen ($(du -h "$DST" | cut -f1))"
else
  log "mem-pull: noch kein Gedaechtnis fuer $NAME, Claude-Mem startet leer"
fi

# Sitzungskennung fuer eine eventuelle Konfliktdatei (stabil fuer die ganze Sitzung)
TAG="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
{
  echo "name=$NAME"
  echo "key=$KEY"
  echo "dir=$PDIR"
  echo "base=$BASE"
  echo "tag=$TAG"
  echo "mode=normal"
} > "$MEM_STATE"
exit 0
