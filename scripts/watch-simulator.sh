#!/usr/bin/env bash
#
# Souvera Simulator Watcher
#
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Läuft bis CTRL+C und überwacht den CI-Workflow des Souvera-iOS-Repos.
# Sobald ein NEUER erfolgreicher Lauf abgeschlossen ist, wird das Artefakt
# "Souvera Simulator App" heruntergeladen, entpackt (alte Dateien werden
# vorher gelöscht) und in den iOS-Simulator installiert.
#
# Voraussetzungen:
#   - Xcode installiert (liefert xcrun/simctl und python3)
#   - Ein GitHub-Token mit Lesezugriff auf Actions (fine-grained,
#     "Actions: Read" auf PhiGi87/souvera_ios) - der Artefakt-Download
#     verlangt Authentifizierung, auch bei öffentlichen Repos.
#
# Verwendung:
#   GITHUB_TOKEN=ghp_xxxx ./scripts/watch-simulator.sh
#
# Konfiguration über Umgebungsvariablen (alle optional):
#   REPO          Standard: PhiGi87/souvera_ios
#   BRANCH        Standard: souvera/push-proxy-wiring
#   WORKFLOW_FILE Standard: souvera-release.yml
#   ARTIFACT_NAME Standard: Souvera Simulator App
#   DEVICE        Standard: iPhone 17
#   INTERVAL      Poll-Intervall in Sekunden, Standard: 60

set -euo pipefail

REPO="${REPO:-PhiGi87/souvera_ios}"
BRANCH="${BRANCH:-souvera/push-proxy-wiring}"
WORKFLOW_FILE="${WORKFLOW_FILE:-souvera-release.yml}"
ARTIFACT_NAME="${ARTIFACT_NAME:-Souvera Simulator App}"
DEVICE="${DEVICE:-iPhone 17}"
INTERVAL="${INTERVAL:-60}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

WORKDIR="${WORKDIR:-$HOME/.souvera/sim}"
STATE_FILE="$WORKDIR/last_run_id"
APP_BUNDLE_ID="eu.souvera.workspace"

log()  { echo "[$(date +%H:%M:%S)] $*"; }

api() {
    curl -sS --retry 2 --retry-delay 2 \
        -H "Accept: application/vnd.github+json" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "$@"
}

download() {
    curl -sSL --retry 2 --retry-delay 2 \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "$@"
}

json_get() {
    python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for key in sys.argv[1:]:
    if isinstance(d, list):
        d = d[int(key)]
    elif isinstance(d, dict):
        d = d.get(key)
    else:
        raise SystemExit(0)
    if d is None:
        raise SystemExit(0)
print(d)' "$@"
}

cleanup_workdir() {
    rm -rf "$WORKDIR/download" "$WORKDIR/unpacked" "$WORKDIR/artifact.zip"
    mkdir -p "$WORKDIR/download" "$WORKDIR/unpacked"
}

# Simulator starten und warten, bis er aktiv ist.
ensure_simulator() {
    local udid
    udid=$(xcrun simctl list devices available \
        | grep -F "$DEVICE (" \
        | grep -oE '[0-9A-F-]{36}' \
        | head -1)

    if [ -z "$udid" ]; then
        log "Gerät '$DEVICE' nicht gefunden. Verfügbare Geräte:"
        xcrun simctl list devices available | grep -E 'iPhone|iPad' || true
        return 1
    fi

    if ! xcrun simctl list devices booted | grep -qF "$udid"; then
        log "Starte Simulator $DEVICE ..."
        xcrun simctl boot "$udid" 2>/dev/null || true
    fi

    # bootstatus wartet, bis der Simulator einsatzbereit ist
    if xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1; then
        return 0
    fi

    # Fallback: pollend auf "Booted" warten
    local i
    for i in $(seq 1 90); do
        if xcrun simctl list devices | grep -F "$udid (" | grep -q Booted; then
            return 0
        fi
        sleep 2
    done
    log "Simulator wurde nicht rechtzeitig aktiv."
    return 1
}

# Neuesten Run des Workflows abfragen.
fetch_latest_run() {
    api "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?branch=$BRANCH&per_page=1"
}

trap 'echo; log "Gestoppt. Bis zum nächsten Mal!"; exit 0' INT TERM

mkdir -p "$WORKDIR"

echo "=============================================="
echo " Souvera Simulator Watcher"
echo "=============================================="
echo "  Repo:      $REPO"
echo "  Branch:    $BRANCH"
echo "  Workflow:  $WORKFLOW_FILE"
echo "  Artefakt:  $ARTIFACT_NAME"
echo "  Gerät:     $DEVICE"
echo "  Intervall: ${INTERVAL}s"
if [ -z "$GITHUB_TOKEN" ]; then
    echo "  Hinweis:   GITHUB_TOKEN nicht gesetzt - es kann nur gemeldet,"
    echo "             aber nicht heruntergeladen werden."
fi
echo "  Stoppen:   CTRL+C"
echo "=============================================="
echo

while true; do
    RUNS_JSON="$(fetch_latest_run || true)"

    RUN_ID="$(printf '%s' "$RUNS_JSON" | json_get workflow_runs 0 id)"
    STATUS="$(printf '%s' "$RUNS_JSON" | json_get workflow_runs 0 status)"
    CONCLUSION="$(printf '%s' "$RUNS_JSON" | json_get workflow_runs 0 conclusion)"
    RUN_SHA="$(printf '%s' "$RUNS_JSON" | json_get workflow_runs 0 head_sha | cut -c1-7)"

    if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "None" ]; then
        log "Keine Run-Info von GitHub (Netzwerk/Token?) - versuche es erneut."
        sleep "$INTERVAL"
        continue
    fi

    LAST_ID="$(cat "$STATE_FILE" 2>/dev/null || true)"

    if [ "$STATUS" != "completed" ]; then
        log "Run #$RUN_ID läuft noch ($STATUS, Commit $RUN_SHA) - warte ..."
        sleep "$INTERVAL"
        continue
    fi

    if [ "$CONCLUSION" != "success" ]; then
        log "Neuester Run #$RUN_ID ist fehlgeschlagen ($CONCLUSION, Commit $RUN_SHA) - CI ist rot, warte auf den nächsten Versuch."
        sleep "$INTERVAL"
        continue
    fi

    if [ "$RUN_ID" = "$LAST_ID" ]; then
        log "Kein neuer Build (zuletzt installiert: Run #$RUN_ID, Commit $RUN_SHA)."
        sleep "$INTERVAL"
        continue
    fi

    log "Neuer erfolgreicher Build: Run #$RUN_ID (Commit $RUN_SHA) - lade Artefakt ..."

    ARTIFACT_ID="$(api "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts" \
        | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
name = sys.argv[1]
for a in d.get("artifacts", []):
    if a.get("name") == name:
        print(a["id"])
        raise SystemExit(0)' "$ARTIFACT_NAME")"

    if [ -z "$ARTIFACT_ID" ]; then
        log "Run #$RUN_ID hat kein Artefakt '$ARTIFACT_NAME' - überspringe ihn."
        printf '%s' "$RUN_ID" > "$STATE_FILE"
        sleep "$INTERVAL"
        continue
    fi

    cleanup_workdir

    if ! download "https://api.github.com/repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" \
            -o "$WORKDIR/artifact.zip"; then
        log "Download fehlgeschlagen - versuche es im nächsten Zyklus erneut."
        sleep "$INTERVAL"
        continue
    fi

    # Das Artefakt-ZIP enthält ein weiteres ZIP (Souvera.app.zip) -> zweistufig entpacken.
    if ! unzip -o -q "$WORKDIR/artifact.zip" -d "$WORKDIR/download"; then
        log "Entpacken fehlgeschlagen (kein gültiges ZIP?) - überspringe."
        sleep "$INTERVAL"
        continue
    fi

    APP_ZIP="$(find "$WORKDIR/download" -maxdepth 1 -name '*.zip' | head -1)"
    if [ -z "$APP_ZIP" ]; then
        log "Keine .zip im Artefakt gefunden - überspringe."
        sleep "$INTERVAL"
        continue
    fi

    unzip -o -q "$APP_ZIP" -d "$WORKDIR/unpacked"

    APP_PATH="$(find "$WORKDIR/unpacked" -maxdepth 1 -name '*.app' -type d | head -1)"
    if [ -z "$APP_PATH" ]; then
        log "Keine .app im ZIP gefunden - überspringe."
        sleep "$INTERVAL"
        continue
    fi

    log "Installiere $APP_PATH in den Simulator ..."

    if ! ensure_simulator; then
        sleep "$INTERVAL"
        continue
    fi

    if xcrun simctl install booted "$APP_PATH"; then
        printf '%s' "$RUN_ID" > "$STATE_FILE"
        log "Fertig! Run #$RUN_ID (Commit $RUN_SHA) ist im Simulator installiert."
        log "Du kannst die App 'Souvera' jetzt im Simulator starten."
    else
        log "Installation fehlgeschlagen - versuche es im nächsten Zyklus erneut."
    fi

    sleep "$INTERVAL"
done
