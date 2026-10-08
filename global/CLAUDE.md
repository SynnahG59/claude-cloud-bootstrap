<!-- claude-cloud-bootstrap:managed – wird bei jedem Sitzungsstart aus dem
     oeffentlichen Repo claude-cloud-bootstrap neu geschrieben. Hier nur
     allgemeine Regeln; Projektwissen gehoert in die CLAUDE.md des Projekts. -->

# Globale Arbeitsregeln (alle Projekte)

## Sprache und Kommunikation
- Antworte auf Deutsch, Code, Commits und Code-Kommentare bleiben im Stil des Projekts.
- Erst verstehen, dann handeln: bei unklaren Anforderungen kurz nachfragen statt raten.
- Ergebnisse ehrlich berichten: fehlgeschlagene Tests, uebersprungene Schritte und
  offene Punkte immer nennen.

## Arbeitsweise
- Die CLAUDE.md und die Konventionen des aktuellen Projekts haben Vorrang vor diesen
  allgemeinen Regeln.
- Kleine, nachvollziehbare Aenderungen; vorhandene Muster und Namen im Projekt nutzen.
- Vor dem Abschluss die schnellen Pruefungen des Projekts ausfuehren (Lint, Typen,
  betroffene Tests), soweit vorhanden.
- Nicht committen, pushen, mergen oder Dateien loeschen, ohne dass es verlangt wurde.

## Sicherheit
- Niemals Tokens, Passwoerter oder Schluessel ausgeben, loggen, in Dateien schreiben
  oder committen. Zugangsdaten nur ueber Umgebungsvariablen verwenden.
- `.env`-Dateien und `~/.ssh` werden nicht gelesen.

## Werkzeugkasten
- Context-mode: fuer grosse Ausgaben und Recherchen die Context-mode-Werkzeuge nutzen,
  damit das Kontextfenster frei bleibt.
- Claude-Mem: Erinnerungen sind pro Projekt getrennt (Projekt = Git-Remote
  `owner/repo`). Projektuebergreifend nur suchen, wenn es ausdruecklich verlangt wird.
- Allgemeine Skills und MCP-Server kommen aus dem Plugin `global-kit`.
