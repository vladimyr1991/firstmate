#!/usr/bin/env bash
# fm-quota-dash.sh - an htop-style console dashboard of fleet resource headroom.
#
# Wraps `quota-axi --json`, which reports a snapshot and has no watch mode of
# its own. This adds the gauges, the table, and the refresh loop.
#
# Layout follows htop deliberately: a stack of fuel gauges at the top for the
# glance, a detail table below for the answer, and a key bar at the bottom. The
# captain reads the gauges in a second and only drops to the table when one of
# them has gone amber.
#
# Top-level sections keep short-cycle and long-cycle limits from blending:
#   WEEKLY LIMIT  - windows of about a week (kind weekly, billing credits, or
#                   multi-day cycles)
#   DAILY LIMIT   - short cycles (session/5h, true daily, image daily cap)
#   UNKNOWN LIMIT - rows whose cycle length is not known, shown last and only
#                   when there are any
# A flat list made a green weekly bar hide an exhausted session. Sectioning
# answers "is the week burned?" and "is today's/session budget burned?" apart.
#
# A section heading is a CLAIM about every row under it, so a row appears in
# WEEKLY or DAILY only when that claim is true of it. A row we could not
# measure - and a window whose cycle nothing in the payload states - is never
# filed under the nearest plausible heading; it goes to UNKNOWN LIMIT, which
# sits last so an unmeasured row cannot push an actionable one down the screen.
#
# Refresh is ONE HOUR by default, not htop's one second. Quota windows are
# weekly, so a fast poll would redraw an unchanged picture while hammering each
# provider's endpoint. No countdown is shown: a ticking number invites watching
# a clock instead of reading the gauges, and press `r` when you cannot wait.
#
# The dashboard shows only quota windows that can bound a model the fleet
# dispatches to. Per-product windows for products the fleet does not dispatch
# to stay in quota-axi's source data but are not dashboard resources. Grok's
# shared credits also carry an explicit unmeasured-weekly-cap warning, because
# a healthy prepaid balance does not prove that Grok can accept another worker.
# That warning rides the gauge, which every terminal width draws, so a narrow
# pane can never quietly turn the caveat back into an unqualified number.
#
# A dispatch provider that answers with quota data but none of those windows
# gets one explicit "dispatch limit not reported" row carrying no number at
# all, filed under UNKNOWN LIMIT. The uncertainty is disclosed rather than
# filled in: the provider stays eligible, but nothing on that row may be read
# as sustainable headroom - and no section claims the row as its own.
#
# The image row reads the same state/image-gen-spend.tsv that bin/fm-image-gen.sh
# writes, so the dashboard and the tool's own cap can never drift apart.
#
# A provider whose quota cannot be read is shown as UNREADABLE, never as 0%.
# Zero would claim "quota exhausted" - a different and far more alarming fact
# than "we could not ask".
#
# Usage:
#   fm-quota-dash.sh [--interval <seconds>] [--provider <list>] [--once]
# Keys: r = refresh now, q = quit.
set -u

INTERVAL=3600
PROVIDERS=claude,codex,grok
ONCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)
      [ $# -ge 2 ] || { echo "fm-quota-dash: --interval requires seconds" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*|0*) echo "fm-quota-dash: --interval must be a positive integer" >&2; exit 2 ;; esac
      INTERVAL=$2; shift 2 ;;
    --provider)
      [ $# -ge 2 ] || { echo "fm-quota-dash: --provider requires a list" >&2; exit 2; }
      PROVIDERS=$2; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "fm-quota-dash: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v quota-axi >/dev/null 2>&1 || { echo "fm-quota-dash: quota-axi is not on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-quota-dash: jq is required" >&2; exit 2; }

if [ -t 1 ]; then
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
  GREEN=$'\033[32m'; AMBER=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; BLUE=$'\033[34m'
  HDR=$'\033[46m\033[30m'; KEY=$'\033[42m\033[30m'; LBL=$'\033[44m\033[37m'
  SEC=$'\033[45m\033[30m'
else
  R=; B=; D=; GREEN=; AMBER=; RED=; CYAN=; BLUE=; HDR=; KEY=; LBL=; SEC=
fi

# Colour follows the captain's own switching rule: below 20% remaining the plan
# is to move work elsewhere, so that is where a gauge stops being calm.
tone_for() {
  awk -v p="$1" -v g="$GREEN" -v a="$AMBER" -v r="$RED" \
    'BEGIN { if (p < 5) printf "%s", r; else if (p < 20) printf "%s", a; else printf "%s", g }'
}

# quota-axi emits ISO-8601 in UTC (Z or +00:00). macOS date -j without -u
# treats the clock fields as local time, so a reset still an hour out already
# rendered as "now" under CEST. Always parse the Y-M-DTh:m:s fields as UTC.
#
# A zone designator is APPLIED, never dropped: discarding "+02:00" would move
# the reset two hours the wrong way, the same class of error as reading UTC
# fields as local time. The offset is kept beside the clock fields and handed
# to strptime's %z; only a stamp with no designator at all is read as UTC.
human_until() {
  local raw base off t now d
  [ -n "$1" ] && [ "$1" != null ] || { printf '?'; return; }
  raw=$1
  # Split the zone designator off first - fractional seconds sit between the
  # clock and the offset, so trimming them first would take the offset too.
  case "$raw" in
    *Z|*z) off=+0000; base=${raw%?} ;;
    *[+-][0-9][0-9]:[0-9][0-9]) off=${raw: -6}; off=${off%:*}${off#*:}; base=${raw%??????} ;;
    *[+-][0-9][0-9][0-9][0-9]) off=${raw: -5}; base=${raw%?????} ;;
    *) off=; base=$raw ;;
  esac
  base=${base%%.*}
  t=$(date -j -u -f "%Y-%m-%dT%H:%M:%S${off:+%z}" "$base$off" +%s 2>/dev/null) \
    || t=$(date -u -d "$raw" +%s 2>/dev/null) \
    || t=$(date -d "$raw" +%s 2>/dev/null) \
    || { printf '?'; return; }
  now=$(date +%s); d=$(( t - now ))
  [ "$d" -gt 0 ] || { printf 'now'; return; }
  if   [ "$d" -ge 86400 ]; then printf '%dd %dh' $(( d / 86400 )) $(( d % 86400 / 3600 ))
  elif [ "$d" -ge 3600 ];  then printf '%dh %dm' $(( d / 3600 )) $(( d % 3600 / 60 ))
  else printf '%dm' $(( d / 60 ))
  fi
}

# BSD seq counts DOWN when first > last (seq 1 0 prints 1 and 0). A 0% bar
# must be empty, so never call seq with a non-positive count.
repeat_char() {
  local ch=$1 n=$2
  [ "$n" -gt 0 ] 2>/dev/null || return 0
  printf "%${n}s" '' | tr ' ' "$ch"
}

# Rows are collected once per refresh into a TSV cache, so the gauge block and
# the detail table below it can never disagree about the same number.
# Columns: section  provider  plan  window  pct  resets
# section is "week", "day" or "unknown" - see bucket rule in collect().
ROWS=

collect() {
  local json img
  json=$(quota-axi --provider "$PROVIDERS" --json 2>/dev/null)
  # Bucket rule (single owner of row placement). Each branch demands POSITIVE
  # evidence for the claim its section makes; nothing falls through to the
  # nearest plausible heading:
  #   week    - kind weekly, a credit balance, a weekly id/label, cycle >= 2 days
  #   day     - a session/hourly/daily kind or id/label, or a sub-2-day cycle
  #   unknown - the payload states no cycle length, so neither claim is true
  # Time remaining is not a cycle length: a weekly credit balance may have one
  # day left, so credits remain weekly at every point in the cycle. A credit
  # balance is a billing-cycle balance and never today's or this session's
  # budget, so it stays weekly whether or not quota-axi carried a resetsAt -
  # a nullable timestamp must not move the same resource between sections.
  ROWS=$(printf '%s' "$json" | jq -r '
    def cycle_secs:
      (.windowSeconds // .pace.cycleSeconds // 0);
    def naming:
      ((.id // "") + " " + (.label // ""));
    def is_credits:
      ((.kind // "") == "credits") or (naming | test("credit"; "i"));
    def section:
      if (.kind // "") == "weekly" then "week"
      elif is_credits then "week"
      elif (naming | test("week|seven[_ -]?day"; "i")) then "week"
      elif (cycle_secs >= 172800) then "week"
      elif ((.kind // "") | test("^(daily|session|hourly)$"; "i")) then "day"
      elif (naming | test("session|five[_ -]?hour|5h|hourly|daily"; "i")) then "day"
      elif (cycle_secs > 0) then "day"
      else "unknown"
      end;
    .providers[]? | (.provider) as $p | (.plan // "?") as $plan |
    (($p == "claude") or ($p == "codex") or ($p == "grok")) as $dispatch_provider |
    [ .windows[]? ] as $reported |
    [ $reported[] |
      select(
        if $p == "claude" then .id == "five_hour" or .id == "seven_day"
        elif $p == "codex" then .id == "weekly"
        elif $p == "grok" then .id == "credits"
        else true
        end
      )
    ] as $dispatch_windows |
    # bash collapses runs of tabs when IFS is whitespace, so an empty field
    # would silently shift every later column; no field is ever emitted empty.
    (if ($dispatch_windows | length) > 0 then
      $dispatch_windows[] |
      [section, $p, $plan, (.label // .id // "window"),
       ((.percentRemaining // -1) | tostring), (.resetsAt // "")]
    elif $dispatch_provider and ($reported | length) > 0 then
      ["unknown", $p, $plan, "-", "unknown", ""]
    else ["unknown", $p, $plan, "-", "-1", ""] end)
    | map(tostring | if . == "" then "-" else . end) | @tsv' 2>/dev/null)

  img=$(image_row) && ROWS="${ROWS}${ROWS:+$'\n'}${img}"
}

image_row() {
  local home ledger cap spent today pct reset
  home="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  ledger="${FM_STATE_OVERRIDE:-$home/state}/image-gen-spend.tsv"
  cap=5
  [ ! -f "$home/config/image-daily-usd-cap" ] || cap=$(tr -d '[:space:]' < "$home/config/image-daily-usd-cap")
  case "$cap" in ''|*[!0-9.]*) cap=5 ;; esac
  today=$(date -u +%Y-%m-%d); spent=0
  [ ! -f "$ledger" ] || spent=$(awk -F'\t' -v d="$today" '$1 == d { s += $4 } END { printf "%.4f", s + 0 }' "$ledger" 2>/dev/null)
  case "$spent" in ''|*[!0-9.]*) spent=0 ;; esac
  pct=$(awk -v s="$spent" -v c="$cap" 'BEGIN { r = (c > 0) ? (1 - s / c) * 100 : 0; if (r < 0) r = 0; printf "%.1f", r }')
  # Midnight UTC is a known reset; Z marks UTC so human_until() does not treat
  # the clock fields as local time.
  reset="$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d tomorrow +%Y-%m-%d)T00:00:00Z"
  printf 'day\timages\tnano-banana\tDaily $%s/$%s\t%s\t%s' \
    "$spent" "$cap" "$pct" "$reset"
}

# One owner of the availability caveat a gauge line carries: its text, its
# dimming, and the columns it costs all come from here, so the width reserved
# for it can never drift from the string actually printed.
caveat_suffix() {  # <note>
  case "$1" in -) return 0 ;; esac
  printf ' %s(%s)%s' "$D" "$1" "$R"
}

# Visible columns caveat_suffix() adds: the escape sequences that dim it print
# no columns at all, so they are measured out rather than assumed away.
caveat_width() {  # <note>
  local suffix
  suffix=$(caveat_suffix "$1")
  [ -n "$suffix" ] || { printf '0'; return; }
  printf '%d' $(( ${#suffix} - ${#D} - ${#R} ))
}

# Everything on a gauge line except the bar itself: "NN [" + " NNN.N%]" + " "
# + model + " (" + window + ")" plus any caveat - measured, not guessed, so the
# bar shrinks by exactly what the rest of the line needs instead of wrapping.
line_overhead() {  # <model> <window> <note>
  printf '%d' $(( 16 + ${#1} + ${#2} + $(caveat_width "$3") ))
}

# One bar width for the whole stack, taken from the LONGEST line in ROWS. A
# per-row width made two rows at the same percentage draw different bar
# lengths and knocked the numbers out of column - the gauges are read by
# comparing them, so equal percentages must look equal.
gauge_width() {  # <cols>
  local cols=$1 longest=0 overhead width sec prov plan win pct resets
  while IFS=$'\t' read -r sec prov plan win pct resets; do
    [ -n "$prov" ] || continue
    overhead=$(line_overhead "$prov" "$win" "$(availability_note "$prov")")
    [ "$overhead" -le "$longest" ] || longest=$overhead
  done <<EOF
$ROWS
EOF
  width=$(( cols - longest ))
  [ "$width" -ge 10 ] || width=10
  [ "$width" -le 40 ] || width=40
  printf '%d' "$width"
}

gauge() {  # <n> <pct> <model> <window> <note> <width>
  local n=$1 pct=$2 model=$3 win=$4 note=$5 width=$6 filled tone pipes spaces caveat
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { f = int(p / 100 * w); if (f < 0) f = 0; if (f > w) f = w; print f }')
  tone=$(tone_for "$pct")
  pipes=$(repeat_char '|' "$filled")
  spaces=$(repeat_char ' ' $(( width - filled )))
  # The caveat rides the gauge, which every terminal width shows, so a narrow
  # pane cannot turn a disclosed uncertainty into an unqualified number.
  caveat=$(caveat_suffix "$note")
  printf '%s%2d%s [%s%s%s%s %s%s%5.1f%%%s%s]%s %s%s%s %s(%s)%s%s\n' \
    "$CYAN" "$n" "$R" "$tone" "$pipes" "$R" "$spaces" "$B" "$tone" "$pct" "$R" "$CYAN" "$R" \
    "$B" "$model" "$R" "$D" "$win" "$R" "$caveat"
}

availability_note() {
  case "$1" in
    grok) printf 'weekly cap unmeasured' ;;
    *) printf '-' ;;
  esac
}

section_title() {
  local label=$1
  printf '%s%s%s\n' "$SEC" " $label " "$R"
}

# Membership has one owner, and UNKNOWN is the catch-all rather than a fourth
# named bucket: every row is drawn under exactly one heading, so no row can
# fall between the sections and disappear from the dashboard entirely.
row_in_section() {  # <row-section> <wanted-section>
  case "$2" in
    unknown) case "$1" in week|day) return 1 ;; *) return 0 ;; esac ;;
    *) [ "$1" = "$2" ] ;;
  esac
}

section_has_rows() {  # <section>
  local want=$1 sec prov rest
  while IFS=$'\t' read -r sec prov rest; do
    [ -n "$prov" ] || continue
    row_in_section "$sec" "$want" && return 0
  done <<EOF
$ROWS
EOF
  return 1
}

# Print gauges for one section. Updates global _ID and _ANY.
render_gauges() {
  local want=$1 width=$2
  local sec prov plan win pct resets note caveat
  _ANY=0
  while IFS=$'\t' read -r sec prov plan win pct resets; do
    [ -n "$prov" ] || continue
    row_in_section "$sec" "$want" || continue
    _ANY=1
    _ID=$(( _ID + 1 ))
    note=$(availability_note "$prov")
    caveat=$(caveat_suffix "$note")
    if [ "$pct" = unknown ]; then
      printf '%s%2d%s [%sUNKNOWN - dispatch limit not reported%s] %s%s%s%s\n' \
        "$CYAN" "$_ID" "$R" "$AMBER" "$R" "$B" "$prov" "$R" "$caveat"
    elif awk -v p="$pct" 'BEGIN { exit !(p < 0) }'; then
      printf '%s%2d%s [%sUNREADABLE - run: quota-axi --allow-keychain-prompt%s] %s%s%s%s\n' \
        "$CYAN" "$_ID" "$R" "$AMBER" "$R" "$B" "$prov" "$R" "$caveat"
    else
      gauge "$_ID" "$pct" "$prov" "$win" "$note" "$width"
    fi
  done <<EOF
$ROWS
EOF
  if [ "$_ANY" -eq 0 ]; then
    printf '%s  (none)%s\n' "$D" "$R"
  fi
}

# Print the detail table for one section. Restarts IDs from _ID_BASE so gauge
# and table IDs match within the section; continues the global sequence.
#
# The column layout has exactly ONE owner per mode: each row builds its cells
# as strings and hands them to a single format. Six hand-aligned printf lines
# meant a column tweak could be applied to five of them and drift in the sixth.
render_table() {
  local want=$1 table_mode=$2
  local sec prov plan win pct resets n note win_cell rem_cell resets_cell note_cell
  n=$_ID_BASE
  _ANY=0
  case "$table_mode" in
    full)    printf '%s%s%s\n' "$HDR" " ID MODEL    PLAN         WINDOW           REMAINING   RESETS     AVAILABILITY" "$R" ;;
    compact) printf '%s%s%s\n' "$HDR" " ID MODEL    WINDOW           REMAINING " "$R" ;;
  esac
  while IFS=$'\t' read -r sec prov plan win pct resets; do
    [ -n "$prov" ] || continue
    row_in_section "$sec" "$want" || continue
    _ANY=1
    n=$(( n + 1 ))
    note=$(availability_note "$prov")
    # A row with no readable number carries no window and no reset either: the
    # cells say "-" rather than borrowing a value the number cannot support.
    win_cell=-
    resets_cell=$(printf '%-10s' -)
    note_cell=$note
    if [ "$pct" = unknown ]; then
      rem_cell=$(printf '%s%9s%s' "$AMBER" "unknown" "$R")
      note_cell='dispatch limit not reported'
      case "$note" in -) ;; *) note_cell="$note_cell; $note" ;; esac
    elif awk -v p="$pct" 'BEGIN { exit !(p < 0) }'; then
      rem_cell=$(printf '%s%9s%s' "$AMBER" "n/a" "$R")
    else
      win_cell=$win
      rem_cell=$(printf '%s%8.1f%%%s' "$(tone_for "$pct")" "$pct" "$R")
      resets_cell=$(printf '%s%-10s%s' "$D" "$(human_until "$resets")" "$R")
    fi
    case "$table_mode" in
      full)
        printf '%s%3d%s %s%-8s%s %s%-12s%s %-16s %s   %s %s\n' \
          "$CYAN" "$n" "$R" "$B" "$prov" "$R" "$BLUE" "$plan" "$R" \
          "$win_cell" "$rem_cell" "$resets_cell" "$note_cell" ;;
      compact)
        printf '%s%3d%s %s%-8s%s %-16s %s\n' \
          "$CYAN" "$n" "$R" "$B" "$prov" "$R" "$win_cell" "$rem_cell" ;;
    esac
  done <<EOF
$ROWS
EOF
  if [ "$_ANY" -eq 0 ]; then
    printf '%s  (none)%s\n' "$D" "$R"
  fi
  _ID=$n
}

# Renders the full dashboard to stdout. draw() then shows it through a
# viewport, so nothing can be pushed off the top of a short terminal.
render_all() {
  local cols table_mode total width sec prov
  # COLUMNS wins when the environment states a width: tput reports the terminal
  # it can see, which is neither the caller's pane nor a stable value when the
  # dashboard is piped. Both agree in an ordinary interactive run.
  cols=${COLUMNS:-}
  case "$cols" in ''|*[!0-9]*|0) cols=$( { tput cols; } 2>/dev/null || echo 80) ;; esac
  case "$cols" in ''|*[!0-9]*|0) cols=80 ;; esac
  if [ "$cols" -ge 70 ]; then table_mode=full
  else                        table_mode=compact
  fi
  width=$(gauge_width "$cols")

  total=0
  while IFS=$'\t' read -r sec prov _; do
    [ -n "$prov" ] || continue
    total=$(( total + 1 ))
  done <<EOF
$ROWS
EOF

  _ID=0
  section_title "WEEKLY LIMIT"
  render_gauges week "$width"
  printf '\n'
  _ID_BASE=0
  render_table week "$table_mode"
  printf '\n'

  _ID_BASE=$_ID
  section_title "DAILY LIMIT"
  render_gauges day "$width"
  printf '\n'
  render_table day "$table_mode"
  printf '\n'

  # Last, and only when something landed there: an unmeasured row must not push
  # an actionable limit down the screen, and an empty heading would be noise on
  # a fleet whose windows all came back with a cycle.
  if section_has_rows unknown; then
    _ID_BASE=$_ID
    section_title "UNKNOWN LIMIT"
    render_gauges unknown "$width"
    printf '\n'
    render_table unknown "$table_mode"
    printf '\n'
  fi

  printf '%sResources:%s %s%d%s\n' "$CYAN" "$R" "$B" "$total" "$R"
}

OUT=(); SCROLL=0

# The gauges ARE the dashboard; the table is detail behind them. On a short
# terminal the content ran past the top and left the captain looking at the
# table alone - exactly backwards. A viewport with scrolling keeps every part
# reachable regardless of window size.
build() { OUT=(); while IFS= read -r l; do OUT+=("$l"); done < <(render_all); }

draw() {
  local rows avail i last
  rows=$( { tput lines; } 2>/dev/null || echo 24 )
  avail=$(( rows - 3 ))
  [ "$avail" -ge 3 ] || avail=3
  last=$(( ${#OUT[@]} - avail )); [ "$last" -ge 0 ] || last=0
  [ "$SCROLL" -le "$last" ] || SCROLL=$last
  [ "$SCROLL" -ge 0 ] || SCROLL=0

  printf '\033[H\033[J'
  i=$SCROLL
  while [ "$i" -lt $(( SCROLL + avail )) ] && [ "$i" -lt "${#OUT[@]}" ]; do
    printf '%s\n' "${OUT[$i]}"; i=$(( i + 1 ))
  done
  [ "${#OUT[@]}" -le "$avail" ] || \
    printf '%s  j/k scroll - %d-%d of %d%s\n' "$D" $(( SCROLL + 1 )) "$i" "${#OUT[@]}" "$R"
  printf '%s r %s%sRefresh%s  %s q %s%sQuit%s\n' "$KEY" "$R" "$LBL" "$R" "$KEY" "$R" "$LBL" "$R"
}


if [ "$ONCE" -eq 1 ]; then collect; render_all; exit 0; fi

# Alternate screen buffer, the same one htop, vim and less use: the dashboard
# draws on a scratch screen and leaving restores whatever the terminal held
# before it started. Clearing the real screen instead - which is what this did -
# destroys the captain's scrollback and leaves the dashboard behind on exit.
restore_terminal() { printf '\033[?25h\033[?1049l%s' "$R"; }
trap 'restore_terminal; exit 0' INT TERM EXIT
printf '\033[?1049h\033[?25l'

while :; do
  collect
  build
  draw
  # Elapsed time is read from the CLOCK, never counted in loop iterations.
  # A mouse wheel floods stdin with escape sequences; each one satisfies `read`
  # immediately instead of costing its one-second timeout, so an iteration
  # counter raced ahead and scrolling visibly pulled the refresh forward.
  started=$(date +%s)
  while [ $(( $(date +%s) - started )) -lt "$INTERVAL" ]; do
    if read -r -s -n 1 -t 1 key 2>/dev/null; then
      case "$key" in
        q|Q) exit 0 ;;
        r|R) break ;;
        j|J) SCROLL=$(( SCROLL + 1 )); draw ;;
        k|K) SCROLL=$(( SCROLL - 1 )); draw ;;
      esac
    fi
  done
done
