#!/bin/bash
# Legt die Projektvorlage in einem Projekt-Repo an. Wird NIE automatisch
# ausgefuehrt, nur bewusst von Hand:
#
#   bash /opt/claude-cloud-bootstrap/templates/apply-project-template.sh <projektordner>
#
# Vorhandene Dateien werden NIE ueberschrieben, nur fehlende angelegt.
# Committen muss man selbst. Der globale Werkzeugkasten braucht diese Dateien
# nicht; sie sind nur fuer Projektwissen und projektspezifische Einstellungen.

set -uo pipefail
TPL="$(cd "$(dirname "${BASH_SOURCE[0]}")/project" && pwd)"
DEST="${1:-}"

if [ -z "$DEST" ] || [ ! -d "$DEST" ]; then
  echo "Aufruf: $0 <projektordner>" >&2; exit 1
fi
if ! git -C "$DEST" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$DEST ist kein Git-Repo, abgebrochen." >&2; exit 1
fi

for f in CLAUDE.md .claude/settings.json .mcp.json; do
  if [ -e "$DEST/$f" ]; then
    echo "bleibt:    $f (existiert bereits)"
  else
    mkdir -p "$DEST/$(dirname "$f")"
    cp "$TPL/$f" "$DEST/$f"
    echo "angelegt:  $f"
  fi
done
echo "Fertig. Dateien pruefen, ausfuellen und selbst committen."
