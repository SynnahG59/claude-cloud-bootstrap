# claude-cloud-bootstrap

Globaler Werkzeugkasten fuer Claude Code in der Cloud („Master-Claude“): jede
neue Sitzung der Master-Umgebung bekommt automatisch Context-mode, Claude-Mem,
allgemeine MCP-Server, Skills, globale Regeln und Einstellungen, **egal welches
Projekt-Repo geoeffnet wird**. Projekte behalten ihren eigenen Code, ihre
eigene `CLAUDE.md` und ihr eigenes Gedaechtnis.

Dieses Repo ist absichtlich oeffentlich, damit das Setup-Script es **ohne
Anmeldung** laden kann. Es enthaelt keine Tokens, Secrets, IDs oder Daten.

## Global und Projekt

| Ebene | Ort | Inhalt |
|---|---|---|
| **Global** (Benutzer) | `~/.claude/` – kommt aus diesem Repo | Plugins, MCPs, Skills, `CLAUDE.md`, `settings.json`, Hooks |
| **Projekt** | im jeweiligen Projekt-Repo | `CLAUDE.md`, `.claude/settings.json`, `.mcp.json`, `.claude/skills/` |
| **Gedaechtnis** | privates Repo `claude-mem-data` | eine Datenbank pro Projekt |

Claude Code fuehrt Benutzer- und Projektebene beim Start zusammen: jedes Projekt
hat den kompletten Werkzeugkasten, Projekteinstellungen ergaenzen oder
ueberschreiben ihn nur fuer dieses Projekt.

## Warum zwei Phasen

- Claude Code laedt Plugins, MCP-Server, Skills, `CLAUDE.md` und Hooks **beim
  Start**. Was erst ein SessionStart-Hook installiert, ist in dieser Sitzung
  nicht aktiv. Darum installiert das Setup-Script.
- Das Setup-Script laeuft aber, **bevor** Umgebungsvariablen (Token) und der
  GitHub-Proxy verfuegbar sind. Darum laedt erst ein SessionStart-Hook das
  private Gedaechtnis.

```
Phase 1  Setup-Script (= bootstrap.sh), ohne Token
  └─ klont dieses Repo ohne Anmeldung nach /opt/claude-cloud-bootstrap
     └─ install.sh   (nur ueber bootstrap.sh)
          1. Context-mode    feste Version aus versions.env
          2. Claude-Mem      feste Version; Autostart AUS, Projektnamen aus Git-Remote
          3. global-kit      -> ~/.claude/skills/global-kit (MCPs + Skills)
          4. global/CLAUDE.md -> ~/.claude/CLAUDE.md
          5. settings.template.json -> ~/.claude/settings.json (zusammengefuehrt)
Phase 2  Claude-Code-Sitzung laeuft, Token und Proxy sind da
  SessionStart  hooks/session-start.sh
                  1. mem-pull: Gedaechtnis des aktuellen Projekts laden
                  2. nur bei Erfolg: Claude-Mem-Worker starten
                  3. Startkontext von Claude-Mem nachladen
  Stop          mem-sync/mem-push.sh           hoechstens alle 5 Min., im Hintergrund
  SessionEnd    mem-sync/mem-push.sh --force   letzte Sicherung
```

## Gedaechtnis pro Projekt

- Projekt = Git-Remote `owner/repo` des geoeffneten Repos, **immer
  kleingeschrieben**. Dieselbe Repo-URL kann je nach Sitzungsstart
  unterschiedlich geschrieben sein; ohne Vereinheitlichung entstuenden zwei
  Gedaechtnisse fuer ein Projekt. Der SessionStart-Hook gibt Claude-Mem den
  Namen fuer den Projektordner fest vor (`CLAUDE_MEM_PROJECT_ENVIRONMENTS`,
  hat Vorrang vor `CLAUDE_MEM_PROJECT_NAME_SOURCE=git-remote`).
- Ablage: `projects/<owner>__<repo>/claude-mem.db` (kleingeschrieben) in `claude-mem-data`.
  Es wird nur der Ordner des aktuellen Projekts geladen.
- Gesichert wird nur nach erfolgreichem Pull (`.sync-ok`). Gab es vor dem Pull
  schon eine lokale DB, gilt der Pull als nicht erfolgreich.
- Ein Projekt schreibt nur seine eigene Datei. Parallele Sitzungen anderer
  Projekte werden uebernommen, nie ersetzt.
- Parallele Sitzungen **desselben** Projekts: die Projektdatei wird nur ersetzt,
  wenn im Repo noch der beim Pull geladene Stand liegt. Sonst sichert die Sitzung
  nach `projects/<key>/conflicts/<sitzung>.db`. Nichts wird ueberschrieben.
- Enthaelt die lokale DB ein fremdes Projekt, wird nicht gesichert.
- Ohne Git-Remote (kein eindeutiger Projektname) gibt es keinen Sync; Claude-Mem
  bleibt dann in dieser Sitzung aus.

Protokolle: `/tmp/global-setup.log` (Phase 1), `/tmp/claude-mem-sync.log` (Phase 2)
Pruefen: `bash /opt/claude-cloud-bootstrap/verify.sh`

## Einrichtung der Master-Umgebung

Umgebungsmenue in der Titelleiste → Edit:

- *Network access*: Allowed domains `github.com`, `api.github.com`,
  `codeload.github.com`, `raw.githubusercontent.com`; „Allow package managers“ an.
- *Umgebungsvariablen*: `GLOBAL_GH_TOKEN=<fine-grained Token>` nur fuer das private
  Gedaechtnis-Repo (Contents: read/write). Der Token wird nie geloggt oder
  gespeichert.
- *Setup script*: Inhalt von `bootstrap.sh` einfuegen.

Alle Projekte laufen in dieser einen Umgebung. Notschalter:
Umgebungsvariable `GLOBAL_KIT_DISABLE=1`.

## Neues Projekt

Nichts zu tun: jedes Repo bekommt den Werkzeugkasten automatisch. Fuer
Projektwissen optional die Vorlage anlegen (ueberschreibt nie etwas):

```
bash /opt/claude-cloud-bootstrap/templates/apply-project-template.sh <projektordner>
```

## Wo was hingehoert

| Was | Wohin |
|---|---|
| allgemeiner MCP-Server | `global-kit/.mcp.json`, Zugangsdaten nur als `${VAR}` |
| allgemeiner Skill | `global-kit/skills/<name>/SKILL.md` |
| allgemeines Plugin | `install.sh`, Version in `versions.env` |
| allgemeine Regel | `global/CLAUDE.md` |
| allgemeine Einstellung, Berechtigung, Hook | `settings.template.json` |
| Projektwissen, Projekt-MCP, Projekt-Skill | im Projekt-Repo |

**Alles hier ist oeffentlich.** Nichts Persoenliches, keine Tokens, keine IDs,
keine Backups und nichts Projektspezifisches in dieses Repo.
