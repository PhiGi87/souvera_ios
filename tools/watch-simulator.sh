#!/bin/bash
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Souvera simulator watcher:
#   - Watches the "Souvera Workspace - Build" workflow of PhiGi87/souvera_ios
#     on the souvera/* branches.
#   - Shows a compact overview per run (commit, status, live run time).
#   - Keeps a persistent history of the last 10 runs.
#   - On success: downloads "Souvera Simulator App", unzips, installs and
#     launches it on a booted iPhone simulator (bundle id eu.souvera.app).
#   - After finishing, the result screen stays for 15 minutes (or until a new
#     run starts). [h] returns to the history view, [q] quits.
#
# Usage:  ./watch-simulator.sh
# Optional env: GH_TOKEN (avoids API rate limits), REPO, BRANCH_PREFIX,
#               WORKFLOW_NAME, ARTIFACT_NAME, APP_BUNDLE_ID, SIMULATOR

set -u

REPO="${REPO:-PhiGi87/souvera_ios}"
BRANCH_PREFIX="${BRANCH_PREFIX:-souvera/}"
WORKFLOW_NAME="${WORKFLOW_NAME:-Souvera Workspace - Build}"
ARTIFACT_NAME="${ARTIFACT_NAME:-Souvera Simulator App}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-eu.souvera.app}"
SIMULATOR="${SIMULATOR:-iPhone 17}"
POLL_SECONDS="${POLL_SECONDS:-20}"
HOLD_SECONDS="${HOLD_SECONDS:-900}"
HISTORY_FILE="$HOME/.souvera-watcher.history"
HISTORY_MAX=10
WORK_DIR="${TMPDIR:-/tmp}/souvera-watcher"

API="https://api.github.com"

# Colors (only on a terminal)
if [ -t 1 ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

WIDTH=78
LINE=$(printf '%.0s─' $(seq 1 $WIDTH))
DOUBLE=$(printf '%.0s═' $(seq 1 $WIDTH))

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
fail() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET"; }
info() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

now() { date +%s; }

dur() { # seconds -> MM:SS
    local s="$1" m h
    m=$((s / 60)); s=$((s % 60))
    if [ "$m" -ge 60 ]; then
        h=$((m / 60)); m=$((m % 60))
        printf '%d:%02d:%02d' "$h" "$m" "$s"
    else
        printf '%d:%02d' "$m" "$s"
    fi
}

inplace() { printf '\033[2K\r%s' "$*"; }

mb() { # bytes -> "12,3 MB"
    awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'
}

# ---------------------------------------------------------------------------
# JSON helpers (python3 required)
# ---------------------------------------------------------------------------

require_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 wird benötigt (Xcode Command Line Tools installieren: xcode-select --install)"
        exit 1
    fi
}

# get_token: GH_TOKEN env -> gh CLI -> git credential helper
get_token() {
    if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; return 0; fi
    if command -v gh >/dev/null 2>&1; then
        local t
        t=$(gh auth token 2>/dev/null) && { printf '%s' "$t"; return 0; }
    fi
    local t
    # GIT_TERMINAL_PROMPT=0 verhindert haengende GUI-Prompts der Helfer.
    t=$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | awk -F= '/^password=/{print $2}')
    [ -n "$t" ] && printf '%s' "$t"
    return 0
}

TOKEN=$(get_token)

api_get() { # url -> body ("" on failure)
    if [ -n "$TOKEN" ]; then
        curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $TOKEN" "$1" 2>/dev/null
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$1" 2>/dev/null
    fi
}

json_get() { # python-expr < json
    python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null
}

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

# Line format: status|runid|commit|started|duration
load_history() {
    [ -f "$HISTORY_FILE" ] && cat "$HISTORY_FILE" || true
}

save_history() { # status runid commit started duration
    local entry="$1|$2|$3|$4|$5"
    local tmp="$HISTORY_FILE.tmp"
    {
        printf '%s\n' "$entry"
        load_history | awk -F'|' -v id="$2" '$2 != id'
    } | head -n "$HISTORY_MAX" > "$tmp" && mv "$tmp" "$HISTORY_FILE"
}

render_history() {
    local count=0
    load_history | while IFS='|' read -r status runid commit started duration; do
        [ -z "$runid" ] && continue
        count=$((count + 1))
        local mark color
        case "$status" in
            success) mark="✓"; color="$C_GREEN" ;;
            failure) mark="✗"; color="$C_RED" ;;
            *)       mark="•"; color="$C_YELLOW" ;;
        esac
        printf '%s  %-4s %-14s %-8s %-12s %s%s\n' \
            "$color$mark$C_RESET" "$runid" "$commit" "$started" "$duration" "$C_DIM" ""
    done
}

# ---------------------------------------------------------------------------
# Runs API
# ---------------------------------------------------------------------------

latest_head() { # -> "sha8" des Branch-HEAD
    api_get "$API/repos/$REPO/commits/$BRANCH" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
print((d.get("sha") or "")[:8])
'
}

latest_run() { # -> "runid|commit|branch|status|conclusion|started|created"
    api_get "$API/repos/$REPO/actions/runs?per_page=3" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
prefix = sys.argv[1]
name = sys.argv[2]
best = None
for run in d.get("workflow_runs", []):
    # The runs list uses "name" for the workflow name (workflow_name is
    # only present on the single-run response).
    if run.get("name") != name and run.get("workflow_name") != name:
        continue
    branch = run.get("head_branch") or ""
    if not branch.startswith(prefix):
        continue
    best = run
    break
if not best:
    print(""); sys.exit(0)
sha = (best.get("head_sha") or "")[:8]
started = best.get("run_started_at") or best.get("created_at") or ""
created = best.get("created_at") or ""
updated = best.get("updated_at") or ""
rid = best.get("id") or ""
branch = best.get("head_branch") or ""
status = best.get("status") or ""
conclusion = best.get("conclusion") or ""
print("|".join([str(rid), sha, branch, status, conclusion, started, created, updated]))
' "$BRANCH_PREFIX" "$WORKFLOW_NAME"
}

epoch_of() { # iso-time -> epoch
    [ -z "$1" ] && { printf '0'; return; }
    python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$1" 2>/dev/null || printf '0'
}

pretty_started() { # iso-time -> "22.08. 14:03"
    [ -z "$1" ] && { printf '%s' "–"; return; }
    python3 -c "import sys,datetime;d=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).astimezone();print(d.strftime('%d.%m. %H:%M'))" "$1" 2>/dev/null || printf '%s' "–"
}

# ---------------------------------------------------------------------------
# Key handling (works on bash 3.2/macOS)
# ---------------------------------------------------------------------------

read_key() { # timeout in tenths -> single char or ""
    local tenths="$1"
    if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then
        IFS= read -rsn1 -t "0.$tenths" key 2>/dev/null && printf '%s' "$key"
        return 0
    fi
    local old k
    old=$(stty -g 2>/dev/null)
    stty -icanon min 0 time "$tenths" 2>/dev/null
    k=$(dd bs=1 count=1 2>/dev/null)
    stty "$old" 2>/dev/null
    [ -n "$k" ] && printf '%s' "$k"
}

# ---------------------------------------------------------------------------
# Spinner / progress
# ---------------------------------------------------------------------------

SPIN="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
spinner() { # pid label
    local pid="$1" label="$2" i=0 start now
    start=$(now)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(now)
        ch="${SPIN:$((i % ${#SPIN})):1}"
        inplace "  $ch $label … $C_DIM$(dur $((now - start)))$C_RESET"
        i=$((i + 1))
        sleep 0.1
    done
    wait "$pid"
}

# ---------------------------------------------------------------------------
# Install phase
# ---------------------------------------------------------------------------

install_artifact() { # runid commit
    local runid="$1" commit="$2" zip_url artifact_size start phase_start elapsed rate mb_total mb_done
    say "$LINE"

    info "⬇ Download: $ARTIFACT_NAME"

    local json
    json=$(api_get "$API/repos/$REPO/actions/runs/$runid/artifacts")
    if [ -z "$json" ]; then
        fail "Artifakt-Liste konnte nicht geladen werden (Token nötig? GH_TOKEN setzen)"
        return 1
    fi
    zip_url=$(printf '%s' "$json" | python3 -c "import sys,json;d=json.load(sys.stdin);a=[x for x in d.get('artifacts',[]) if x.get('name')=='$ARTIFACT_NAME' and not x.get('expired')];print(a[0]['archive_download_url'] if a else '')" 2>/dev/null)
    artifact_size=$(printf '%s' "$json" | python3 -c "import sys,json;d=json.load(sys.stdin);a=[x for x in d.get('artifacts',[]) if x.get('name')=='$ARTIFACT_NAME'];print(a[0]['size_in_bytes'] if a else 0)" 2>/dev/null)
    if [ -z "$zip_url" ]; then
        fail "Kein Artifakt '$ARTIFACT_NAME' für Run $runid"
        return 1
    fi

    mkdir -p "$WORK_DIR"
    rm -rf "$WORK_DIR/$runid"
    mkdir -p "$WORK_DIR/$runid"

    local curl_args=(-fL --retry 2 --retry-delay 2)
    [ -n "$TOKEN" ] && curl_args+=(-H "Authorization: Bearer $TOKEN")

    phase_start=$(now)
    # Eigene Progressbar: curl -# zeichnet nur auf einem TTY, daher
    # streamen wir und malen die Bar anhand der Dateigröße selbst.
    curl "${curl_args[@]}" -s -o "$WORK_DIR/$runid/artifact.zip" "$zip_url" &
    cpid=$!
    while kill -0 "$cpid" 2>/dev/null; do
        size=$(stat -f%z "$WORK_DIR/$runid/artifact.zip" 2>/dev/null || stat -c%s "$WORK_DIR/$runid/artifact.zip" 2>/dev/null || printf 0)
        elapsed=$(($(now) - phase_start))
        [ "$elapsed" -le 0 ] 2>/dev/null && elapsed=1
        if [ "${artifact_size:-0}" -gt 0 ] && [ "$size" -gt 0 ] 2>/dev/null; then
            pct=$(( size * 100 / artifact_size ))
            [ "$pct" -gt 100 ] && pct=100
            filled=$(( pct * 40 / 100 ))
            bar=$(printf '%.0s#' $(seq 1 "$filled"))
            empty=$(printf '%.0s-' $(seq 1 $(( 40 - filled ))))
            rate=$(( size / elapsed ))
            inplace "  [$bar$empty] $pct%%  $(mb "$size")/$(mb "$artifact_size") MB  ($(mb "$rate") MB/s)"
        else
            inplace "  ⬇ lädt … $(mb "$size") MB  ($(dur $elapsed))"
        fi
        sleep 0.2
    done
    wait "$cpid"
    rc=$?
    printf '\n'
    if [ "$rc" -eq 0 ] && [ -s "$WORK_DIR/$runid/artifact.zip" ]; then
        elapsed=$(($(now) - phase_start))
        [ "$elapsed" -le 0 ] 2>/dev/null && elapsed=1
        size=$(stat -f%z "$WORK_DIR/$runid/artifact.zip" 2>/dev/null || stat -c%s "$WORK_DIR/$runid/artifact.zip" 2>/dev/null || printf 0)
        ok "Download: $(mb "$size")/$(mb "$artifact_size") MB in $(dur $elapsed) ($(mb $(( size / elapsed ))) MB/s)"
    else
        fail "Download fehlgeschlagen (rc=$rc)"
        return 1
    fi

    say "$LINE"

    phase_start=$(now)
    info "⏳ Entpacken: Souvera.app"
    ( cd "$WORK_DIR/$runid" && unzip -o -q artifact.zip >/dev/null 2>&1 ) &
    spinner $! "Entpacke (1/2)"
    # GitHub packt das Artefakt (Souvera.app.zip) selbst noch einmal in ein
    # Zip: daher ggf. ein zweites Mal entpacken.
    if [ ! -d "$WORK_DIR/$runid/Souvera.app" ] && [ -f "$WORK_DIR/$runid/Souvera.app.zip" ]; then
        ( cd "$WORK_DIR/$runid" && unzip -o -q Souvera.app.zip >/dev/null 2>&1 ) &
        spinner $! "Entpacke (2/2)"
    fi
    local app_path="$WORK_DIR/$runid/Souvera.app"
    if [ -d "$app_path" ]; then
        local files
        files=$(find "$app_path" -type f | wc -l | tr -d ' ')
        ok "Entpackt: $files Dateien in $(dur $(($(now) - phase_start)))"
    else
        fail "Souvera.app wurde im Archiv nicht gefunden (Artifakt enthält: $(ls "$WORK_DIR/$runid" | tr '\n' ' '))"
        return 1
    fi

    say "$LINE"

    local booted
    booted=$(xcrun simctl list devices booted 2>/dev/null | awk -F'[(]' '/Booted/{print $2; exit}' | cut -d')' -f1)
    if [ -z "$booted" ]; then
        phase_start=$(now)
        info "⏳ Simulator '$SIMULATOR' booten"
        ( xcrun simctl boot "$SIMULATOR" >/dev/null 2>&1 ) &
        spinner $! "Boote"
        sleep 2
        booted=$(xcrun simctl list devices booted 2>/dev/null | awk -F'[(]' '/Booted/{print $2; exit}' | cut -d')' -f1)
        if [ -z "$booted" ]; then
            fail "Kein Simulator konnte gebootet werden"
            return 1
        fi
        ok "Simulator gebootet: $booted"
    else
        dim "Simulator läuft bereits: $booted"
    fi

    phase_start=$(now)
    info "⏳ Alte App entfernen"
    ( xcrun simctl uninstall "$booted" "$APP_BUNDLE_ID" >/dev/null 2>&1; true ) &
    spinner $! "Deinstalliere"
    ok "App entfernt: $APP_BUNDLE_ID"

    phase_start=$(now)
    info "⏳ Installieren: Souvera.app (Commit $commit)"
    ( xcrun simctl install "$booted" "$app_path" >/dev/null 2>&1 ) &
    spinner $! "Installiere"
    if xcrun simctl install "$booted" "$app_path" >/dev/null 2>&1; then
        ok "Installiert: Build $commit in $(dur $(($(now) - phase_start)))"
    else
        fail "Installation fehlgeschlagen"
        return 1
    fi

    phase_start=$(now)
    info "▶ Launch: $APP_BUNDLE_ID"
    if xcrun simctl launch "$booted" "$APP_BUNDLE_ID" >/dev/null 2>&1; then
        ok "App gestartet ($(dur $(($(now) - phase_start))))"
    else
        fail "Launch fehlgeschlagen"
        return 1
    fi
    say "$LINE"
    return 0
}

# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------

# Zeichnet den KOMPLETTEN statischen Block (nur bei Zustandswechseln).
# Laufende Infos stehen in der letzten Zeile und werden in place aktualisiert.
render_screen() { # runid commit branch status conclusion started updated
    local runid="$1" commit="$2" branch="$3" status="$4" conclusion="$5" started="$6" updated="$7"
    clear 2>/dev/null || true
    say "$DOUBLE"
    printf '%s Souvera Watcher%s\n' "$C_BOLD" "$C_RESET"
    if [ -z "$runid" ]; then
        info "Kein Run gefunden."
    else
        printf 'Letzter Run:  %s  Commit: %s  Branch: %s\n' "$runid" "$commit" "$branch"
        printf 'Gestartet:    %s' "$(pretty_started "$started")"
        if [ "$status" = "completed" ]; then
            local d
            d=$(( $(epoch_of "$updated") - $(epoch_of "$started") ))
            [ "$d" -gt 0 ] 2>/dev/null && printf '   Dauer: %s' "$(dur $d)"
        fi
        say ""
        local head
        head=$(latest_head)
        if [ -n "$head" ] && [ "$head" != "$commit" ]; then
            dim "Branch-HEAD:  $head (Skript-Commit ohne CI-Run)"
        fi
    fi
    say "$LINE"
    local hist
    hist=$(render_history)
    if [ -n "$hist" ]; then
        printf '%sLetzte Runs:%s\n' "$C_BOLD" "$C_RESET"
        printf '%s\n' "$hist"
    fi
    say "$LINE"
    say "$DOUBLE"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

require_python
if [ -z "$TOKEN" ]; then
    dim "Hinweis: kein GitHub-Token gefunden (GH_TOKEN/gh/git) — anonym mit langsamem Polling (60 s)."
    POLL_SECONDS=60
fi

last_runid=""
last_status=""
processed_runid=""
last_poll=0
status_mode=""     # "" = watch, "done" = Abschluss-Screen
hold_deadline=0
screen_runid="__none__"
screen_status="__none__"
wait_started=0

# Einmalige Abfrage beim Start: letzten Run laden und statischen Block zeichnen
run=$(latest_run)
runid=$(printf '%s' "$run" | cut -d'|' -f1)
commit=$(printf '%s' "$run" | cut -d'|' -f2)
branch=$(printf '%s' "$run" | cut -d'|' -f3)
status=$(printf '%s' "$run" | cut -d'|' -f4)
conclusion=$(printf '%s' "$run" | cut -d'|' -f5)
started=$(printf '%s' "$run" | cut -d'|' -f6)
updated=$(printf '%s' "$run" | cut -d'|' -f8)
last_runid="$runid"
last_status="$status"
last_poll=$(now)
render_screen "$runid" "$commit" "$branch" "$status" "$conclusion" "$started" "$updated"
screen_runid="$runid"
screen_status="$status"
wait_started=$(now)

trap 'printf "\n"; stty sane 2>/dev/null; exit 0' INT TERM

while true; do
    now_s=$(now)

    # API nur im Poll-Takt abfragen
    if [ $(( now_s - last_poll )) -ge "$POLL_SECONDS" ]; then
        last_poll=$now_s
        run=$(latest_run)
        runid=$(printf '%s' "$run" | cut -d'|' -f1)
        commit=$(printf '%s' "$run" | cut -d'|' -f2)
        branch=$(printf '%s' "$run" | cut -d'|' -f3)
        status=$(printf '%s' "$run" | cut -d'|' -f4)
        conclusion=$(printf '%s' "$run" | cut -d'|' -f5)
        started=$(printf '%s' "$run" | cut -d'|' -f6)
        updated=$(printf '%s' "$run" | cut -d'|' -f8)

        # Zustandswechsel (neuer Run oder Statuswechsel)?
        if [ "$runid|$status" != "$screen_runid|$screen_status" ]; then
            # Abschluss genau einmal verarbeiten
            if [ -n "$runid" ] && [ "$status" = "completed" ] && [ "$processed_runid" != "$runid" ]; then
                case "$conclusion" in
                    success)
                        ok "Build fertig (Commit $commit) — Installation wird vorbereitet …"
                        total_start=$(now)
                        if install_artifact "$runid" "$commit"; then
                            ok "Fertig in $(dur $(($(now) - total_start)))"
                            save_history "success" "$runid" "$commit" "$(pretty_started "$started")" "$(dur $(($(now) - $(epoch_of "$started"))))"
                        else
                            fail "Installation fehlgeschlagen — nächster Run wird beobachtet"
                            save_history "failure" "$runid" "$commit" "$(pretty_started "$started")" "$(dur $(($(now) - $(epoch_of "$started"))))"
                        fi
                        ;;
                    failure)
                        fail "Build fehlgeschlagen — Log: https://github.com/$REPO/actions/runs/$runid"
                        save_history "failure" "$runid" "$commit" "$(pretty_started "$started")" "$(dur $(($(now) - $(epoch_of "$started"))))"
                        ;;
                    cancelled|skipped)
                        info "Run abgebrochen/übersprungen"
                        save_history "failure" "$runid" "$commit" "$(pretty_started "$started")" "$(dur $(($(now) - $(epoch_of "$started"))))"
                        ;;
                esac
                processed_runid="$runid"
                status_mode="done"
                hold_deadline=$(( $(now) + HOLD_SECONDS ))
            fi

            render_screen "$runid" "$commit" "$branch" "$status" "$conclusion" "$started" "$updated"
            screen_runid="$runid"
            screen_status="$status"
            wait_started=$now_s
            if [ -n "$runid" ] && [ "$status" != "completed" ]; then
                status_mode=""
            fi
        fi
    fi

    # ---- Dynamische letzte Zeile (in place, keine neuen Zeilen) ----
    if [ "$status_mode" = "done" ]; then
        remaining=$(( hold_deadline - now_s ))
        if [ "$remaining" -le 0 ]; then
            status_mode=""
            render_screen "" "" "" "" "" "" ""
            screen_runid=""
            screen_status=""
        else
            inplace "  Zurück zur Übersicht in $(dur $remaining) — [h] sofort · [q] beenden"
            k=$(read_key 5)
            case "$k" in
                h|H)
                    status_mode=""
                    render_screen "$runid" "$commit" "$branch" "$status" "$conclusion" "$started" "$updated"
                    screen_runid="$runid"
                    screen_status="$status"
                    ;;
                q|Q) printf '\n'; exit 0 ;;
            esac
        fi
    elif [ -n "$runid" ] && [ "$status" != "completed" ]; then
        elapsed=$(( now_s - $(epoch_of "$started") ))
        inplace "  Status: läuft · Laufzeit: $(dur $elapsed)"
    else
        waited=$(( now_s - wait_started ))
        inplace "  Kein neuer Run · Warte seit $(dur $waited)"
    fi

    sleep 1
done
