# shellcheck disable=SC2034  # Variablen werden von den einbindenden Scripts genutzt
# Gemeinsame Konstanten und Hilfsfunktionen fuer alle Scripts dieses Repos.
# Wird per "source" eingebunden, nicht direkt ausfuehren.
#
# Enthaelt bewusst KEINE Tokens oder Zugangsdaten. Der Zugang zum privaten
# Gedaechtnis-Repo kommt aus der Umgebungsvariable GLOBAL_GH_TOKEN, die nur
# zur Laufzeit gelesen und nie geloggt oder gespeichert wird.

GH_OWNER="SynnahG59"

# Checkout dieses Repos (im Setup-Script: /opt/claude-cloud-bootstrap)
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
. "$KIT_DIR/versions.env"

MEM_REPO="claude-mem-data"             # privates Repo, eine DB-Datei pro Projekt
MEM_BRANCH="main"
MEM_CHECKOUT="${MEM_CHECKOUT:-/opt/claude-mem-data}"
MEM_STATE="$MEM_CHECKOUT/.sync-ok"     # nur nach erfolgreichem Pull vorhanden
MEM_DATA_DIR="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
MEM_DB_NAME="claude-mem.db"            # Chroma-Index wird NICHT gesichert, er wird aus der DB neu aufgebaut
MEM_SETTINGS="$MEM_DATA_DIR/settings.json"
MEM_SYNC_INTERVAL="${MEM_SYNC_INTERVAL:-300}"   # Sekunden zwischen zwei Sicherungen

GLOBAL_LOG="/tmp/global-setup.log"
MEM_LOG="${MEM_LOG:-/tmp/claude-mem-sync.log}"
MARKER_FILE="$HOME/.claude/global-kit.installed"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# git mit GitHub-Authentifizierung, ohne den Token auf Platte oder in die
# Kommandozeile (ps) zu schreiben. Vorhandene GIT_CONFIG_*-Eintraege der
# Sitzung bleiben erhalten, der Header wird hinten angehaengt.
gh_git() {
  if [ -n "${GLOBAL_GH_TOKEN:-}" ]; then
    local n="${GIT_CONFIG_COUNT:-0}"
    local b64
    b64=$(printf 'x-access-token:%s' "$GLOBAL_GH_TOKEN" | base64 -w0)
    env GIT_TERMINAL_PROMPT=0 \
        GIT_CONFIG_COUNT=$((n + 1)) \
        "GIT_CONFIG_KEY_$n=http.https://github.com/.extraheader" \
        "GIT_CONFIG_VALUE_$n=Authorization: Basic $b64" \
        git "$@"
  else
    GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

gh_url() { printf 'https://github.com/%s/%s.git' "$GH_OWNER" "$1"; }

# Wurzelordner des Projekt-Repos (git toplevel). Leer ohne Git-Repo.
project_dir() {
  git -C "${1:-${CLAUDE_PROJECT_DIR:-$PWD}}" rev-parse --show-toplevel 2>/dev/null || true
}

# Projektname: die letzten zwei Pfadteile der origin-URL, ohne ".git", immer
# kleingeschrieben (z. B. "owner/mein-projekt"). Kleinschreibung, weil dieselbe
# Repo-URL je nach Sitzungsstart unterschiedlich geschrieben sein kann
# (".../Owner/Repo" oder ".../owner/repo"); sonst entstuenden zwei getrennte
# Gedaechtnisse fuer ein Projekt. Leer ohne Git-Repo oder ohne origin.
project_name() {
  local dir="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}" url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  url="${url%/}"; url="${url%.git}"
  case "$url" in
    *://*) url="${url#*://}"; url="${url#*/}" ;;   # https://host/owner/repo
    *:*)   url="${url#*:}" ;;                       # git@host:owner/repo
    *)     return 0 ;;                              # lokaler Pfad: kein Projekt
  esac
  printf '%s\n' "$url" | awk -F/ 'NF >= 2 { print tolower($(NF-1) "/" $NF) }'
}

# Dateischluessel im Gedaechtnis-Repo: "owner/repo" -> "owner__repo".
# Leer, wenn der Name unerwartete Zeichen oder Grossbuchstaben enthaelt
# (dann kein Sync).
project_key() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || return 0
  printf '%s\n' "${name/\//__}"
}

# Plugin-Ordner der installierten Claude-Mem-Version (enthaelt scripts/).
cm_plugin_dir() {
  local base="$HOME/.claude/plugins" d
  for d in "$base/cache/thedotmack/claude-mem/$CLAUDE_MEM_VERSION" \
           "$base/cache/thedotmack/claude-mem/$CLAUDE_MEM_VERSION/plugin" \
           "$base/marketplaces/thedotmack/plugin"; do
    if [ -f "$d/scripts/worker-service.cjs" ] && [ -f "$d/scripts/bun-runner.js" ]; then
      printf '%s\n' "$d"; return 0
    fi
  done
  return 1
}

# Claude-Mem-CLI (Worker und Hooks) ueber den mitgelieferten Bun-Starter.
cm_worker() {
  local d
  d=$(cm_plugin_dir) || return 1
  CLAUDE_PLUGIN_ROOT="$d" node "$d/scripts/bun-runner.js" "$d/scripts/worker-service.cjs" "$@"
}

# Einen Schluessel in ~/.claude-mem/settings.json setzen (Datei bleibt sonst erhalten).
cm_setting() {
  mkdir -p "$MEM_DATA_DIR"
  [ -s "$MEM_SETTINGS" ] || echo '{}' > "$MEM_SETTINGS"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$MEM_SETTINGS" > "$MEM_SETTINGS.tmp" \
    && mv "$MEM_SETTINGS.tmp" "$MEM_SETTINGS" && chmod 600 "$MEM_SETTINGS"
}

# Claude-Mem den festen Projektnamen fuer einen Projektordner vorgeben
# (CLAUDE_MEM_PROJECT_ENVIRONMENTS hat bei Claude-Mem Vorrang vor git-remote).
# So speichert Claude-Mem unabhaengig von der Schreibweise der Remote-URL unter
# demselben, kleingeschriebenen Namen wie die Dateien in claude-mem-data.
# Muster: der Ordner selbst und alles darunter, auch als aufgeloester Pfad.
# Eintraege mit demselben Namen oder denselben Mustern werden ersetzt.
cm_map_project() {
  local name="$1" dir="$2" real
  [ -n "$name" ] && [ -n "$dir" ] || return 1
  real="$(realpath "$dir" 2>/dev/null || printf '%s' "$dir")"
  mkdir -p "$MEM_DATA_DIR"
  [ -s "$MEM_SETTINGS" ] || echo '{}' > "$MEM_SETTINGS"
  jq --arg n "$name" --arg d "$dir" --arg r "$real" '
      ([$d, "\($d)/**"] + (if $r != $d then [$r, "\($r)/**"] else [] end)) as $pat
      | ((.CLAUDE_MEM_PROJECT_ENVIRONMENTS // "[]")
         | (if type == "string" then (try fromjson catch []) else . end)
         | (if type == "array" then . else [] end)) as $cur
      | .CLAUDE_MEM_PROJECT_ENVIRONMENTS = (
          [ $cur[] | select(type == "object" and .name != $n
                            and ([.patterns[]? | select(. as $p | $pat | index($p))] | length == 0)) ]
          + [{name: $n, patterns: $pat}]
          | tojson)
    ' "$MEM_SETTINGS" > "$MEM_SETTINGS.tmp" \
    && mv "$MEM_SETTINGS.tmp" "$MEM_SETTINGS" && chmod 600 "$MEM_SETTINGS"
}
