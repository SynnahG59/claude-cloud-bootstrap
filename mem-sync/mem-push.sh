#!/bin/bash
# Sichert das Claude-Mem-Gedaechtnis des aktuellen Projekts ins private Repo
# claude-mem-data, Datei projects/<owner>__<repo>/claude-mem.db.
#
#   mem-push.sh              Stop-Hook: gedrosselt (MEM_SYNC_INTERVAL), im Hintergrund
#   mem-push.sh --force --fg SessionEnd-Hook: sofort, im Vordergrund
#
# Nie ueberschreiben, was nicht von hier stammt:
#   - Es wird ausschliesslich die Datei des eigenen Projekts geschrieben
#     (git add auf genau diesen Pfad). Andere Projekte liegen in anderen
#     Dateien; ihre Commits werden vor dem Push uebernommen, nicht ersetzt.
#   - Die Projektdatei wird nur ersetzt, wenn im Repo noch genau der Stand
#     liegt, der beim Pull geladen wurde (base). Hat eine parallele Sitzung
#     desselben Projekts inzwischen gesichert, geht der eigene Stand in
#     projects/<key>/conflicts/<sitzung>.db und bleibt dort fuer diese Sitzung.
#   - Enthaelt die DB Daten eines anderen Projekts, wird nicht gesichert.
#   - Nur nach erfolgreichem mem-pull (.sync-ok).
# Gibt immer Exit 0 zurueck und schreibt nichts nach stdout, damit der
# Hook die Sitzung nie stoert. Protokoll: /tmp/claude-mem-sync.log

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "$HERE/../lib/common.sh"

FORCE=0; FG=0
for a in "$@"; do
  case "$a" in --force) FORCE=1 ;; --fg) FG=1 ;; esac
done

# Hook-Eingabe (JSON auf stdin) wird nicht gebraucht
[ -t 0 ] || cat >/dev/null

[ "${GLOBAL_KIT_DISABLE:-0}" = "1" ] && exit 0
# Ohne erfolgreichen Pull gibt es nichts zu tun (auch kein Hintergrundprozess)
[ -f "$MEM_STATE" ] || exit 0

# Im Hintergrund weiterlaufen, damit der Stop-Hook sofort zurueckkehrt
if [ "$FG" = "0" ]; then
  args=(--fg); [ "$FORCE" = "1" ] && args+=(--force)
  nohup setsid bash "${BASH_SOURCE[0]}" "${args[@]}" </dev/null >/dev/null 2>&1 &
  exit 0
fi

exec >>"$MEM_LOG" 2>&1

st_get() { sed -n "s/^$1=//p" "$MEM_STATE" | head -n 1; }
st_set() { sed -i "s|^$1=.*|$1=$2|" "$MEM_STATE"; }

NAME="$(st_get name)"; KEY="$(st_get key)"; BASE="$(st_get base)"
TAG="$(st_get tag)";   MODE="$(st_get mode)"
if [ -z "$NAME" ] || [ -z "$KEY" ] || [ -z "$BASE" ] || [ -z "$TAG" ]; then
  log "mem-push: .sync-ok unvollstaendig, nicht gesichert"; exit 0
fi
REL="projects/$KEY"
MAIN="$REL/$MEM_DB_NAME"
CONFLICT="$REL/conflicts/$TAG.db"

SRC="$MEM_DATA_DIR/$MEM_DB_NAME"
SNAP="$MEM_CHECKOUT/.git/claude-mem-snapshot.db"
STAMP="$MEM_CHECKOUT/.git/claude-mem-last-push"

[ -f "$SRC" ] || { log "mem-push: keine lokale DB"; exit 0; }

if [ "$FORCE" = "0" ] && [ -f "$STAMP" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$STAMP") ))
  [ "$age" -lt "$MEM_SYNC_INTERVAL" ] && exit 0
fi

exec 9>/tmp/claude-mem-sync.lock
flock -n 9 || { log "mem-push: laeuft bereits"; exit 0; }

# Konsistenter Snapshot ueber die SQLite-Backup-API (nie die laufende Datei
# kopieren) und Pruefung, dass nur das eigene Projekt enthalten ist.
python3 -I - "$SRC" "$SNAP.tmp" "$NAME" <<'PY'
import sqlite3, sys
src_path, dst_path, name = sys.argv[1:4]
src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
dst = sqlite3.connect(dst_path)
src.backup(dst)
src.close()
if dst.execute("PRAGMA quick_check").fetchone()[0] != "ok":
    sys.exit(1)
projects = set()
for table in ("sdk_sessions", "observations", "session_summaries"):
    try:
        projects |= {r[0] for r in dst.execute(f"SELECT DISTINCT project FROM {table}")}
    except sqlite3.Error:
        pass
dst.close()
if not projects:
    sys.exit(2)
# Vergleich ohne Gross-/Kleinschreibung: name ist immer kleingeschrieben.
foreign = sorted(p for p in projects
                 if str(p).lower() != name and not str(p).lower().startswith(name + "/"))
if foreign:
    print("fremde Projekte in der DB: " + ", ".join(map(str, foreign)))
    sys.exit(3)
PY
rc=$?
case "$rc" in
  0) ;;
  2) rm -f "$SNAP.tmp"; log "mem-push: noch keine Eintraege, nichts zu sichern"; touch "$STAMP"; exit 0 ;;
  3) rm -f "$SNAP.tmp"; log "mem-push: ABGEBROCHEN, DB enthaelt andere Projekte als $NAME (siehe oben). Nichts gesichert."; exit 0 ;;
  *) rm -f "$SNAP.tmp"; log "mem-push: Snapshot fehlgeschlagen"; exit 0 ;;
esac
mv "$SNAP.tmp" "$SNAP"

g() { git -C "$MEM_CHECKOUT" -c commit.gpgsign=false \
          -c user.name="claude-mem-sync" -c user.email="claude-mem-sync@localhost" "$@"; }

for i in 1 2 3; do
  # Aktuellen Stand holen. Leeres Repo (noch kein main) ist erlaubt.
  if gh_git -C "$MEM_CHECKOUT" fetch -q --depth 1 --filter=blob:none origin "$MEM_BRANCH"; then
    HAVE_REMOTE=1
    REMOTE="$(git -C "$MEM_CHECKOUT" rev-parse -q --verify "FETCH_HEAD:$MAIN" || echo none)"
  elif [ -z "$(gh_git -C "$MEM_CHECKOUT" ls-remote --heads origin "$MEM_BRANCH" 2>/dev/null)" ]; then
    HAVE_REMOTE=0; REMOTE=none
  else
    log "mem-push: fetch fehlgeschlagen, naechster Versuch beim naechsten Hook"; exit 0
  fi

  # Vergleichen, dann tauschen: Projektdatei nur, wenn sie noch dem geladenen Stand entspricht.
  if [ "$MODE" = "normal" ] && [ "$REMOTE" = "$BASE" ]; then
    TARGET="$MAIN"
  else
    if [ "$MODE" != "conflict" ]; then
      MODE=conflict; st_set mode conflict
      log "mem-push: KONFLIKT $NAME wurde parallel gesichert (Stand $REMOTE statt $BASE). Diese Sitzung sichert nach $CONFLICT."
    fi
    TARGET="$CONFLICT"
  fi

  # Schutz vor versehentlichem Ueberschreiben mit einer stark geschrumpften DB
  if [ "$TARGET" = "$MAIN" ] && [ "$BASE" != "none" ]; then
    old=$(gh_git -C "$MEM_CHECKOUT" cat-file -s "$BASE" 2>/dev/null || echo 0)
    new=$(stat -c %s "$SNAP")
    if [ "$old" -gt 1048576 ] && [ "$new" -lt $((old / 2)) ]; then
      log "mem-push: ABGEBROCHEN, neue DB ($new B) < 50% der alten ($old B). Bitte pruefen."
      exit 0
    fi
  fi

  # Arbeitsstand = neuester Stand des Repos; nur der eigene Projektordner ist ausgecheckt.
  if [ "$HAVE_REMOTE" = "1" ]; then
    gh_git -C "$MEM_CHECKOUT" reset -q --hard FETCH_HEAD || { log "mem-push: reset fehlgeschlagen"; exit 0; }
  fi
  mkdir -p "$MEM_CHECKOUT/$(dirname "$TARGET")"
  cp "$SNAP" "$MEM_CHECKOUT/$TARGET"
  g add -- "$TARGET"
  if ! g diff --cached --quiet; then
    MSG="mem $NAME $(date -u +%Y-%m-%dT%H:%M:%SZ)$([ "$TARGET" = "$CONFLICT" ] && echo " (Konflikt $TAG)")"
    g commit -q -m "$MSG" -- "$TARGET" || { log "mem-push: commit fehlgeschlagen"; exit 0; }
  fi
  # Nichts Neues gegenueber dem Repo: fertig.
  if [ "$HAVE_REMOTE" = "1" ] && [ "$(git -C "$MEM_CHECKOUT" rev-parse HEAD)" = "$(git -C "$MEM_CHECKOUT" rev-parse FETCH_HEAD)" ]; then
    touch "$STAMP"; exit 0
  fi
  if [ "$HAVE_REMOTE" = "0" ] && ! git -C "$MEM_CHECKOUT" rev-parse -q --verify HEAD >/dev/null; then
    touch "$STAMP"; exit 0
  fi

  if gh_git -C "$MEM_CHECKOUT" push -q origin "HEAD:$MEM_BRANCH"; then
    if [ "$TARGET" = "$MAIN" ]; then
      BASE="$(git -C "$MEM_CHECKOUT" rev-parse HEAD:"$MAIN")"; st_set base "$BASE"
    fi
    touch "$STAMP"; log "mem-push: gesichert -> $TARGET"; exit 0
  fi
  # Abgelehnt: eine andere Sitzung war schneller. Naechste Runde holt ihren
  # Stand und entscheidet neu (anderes Projekt: einfach darauf aufbauen;
  # dasselbe Projekt: Konfliktdatei).
  sleep $((i * 2))
done
log "mem-push: Push fehlgeschlagen, naechster Versuch beim naechsten Hook"
exit 0
