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
# The detail table is drawn at the width its own columns measure. A pane too
# narrow for that gets the compact table plus the width that brings the dropped
# columns back, and separately the wider one the longest note would need, so
# information is never dropped silently and the two widths are never confused.
# The gauges - and with them Grok's caveat - survive every width.
#
# Cells carrying the provider's own text - a window label above all - are cut
# to what the pane affords and marked with a trailing ~. One vendor label long
# enough to outgrow the terminal would otherwise take the whole grid past the
# edge with it, wrapping every row rather than losing its own tail.
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
# than "we could not ask". The word and the caveat beside it are drawn at every
# width; the command that would fix it is help rather than fact, so a pane too
# narrow for the whole row prints that command once at the bottom instead of
# wrapping every unreadable row.
#
# Every configured provider gets exactly one row, and the configured list - not
# the payload - is what the rows are drawn from. A provider quota-axi omits, or
# that a failed or unparseable run never reported at all, is unread rather than
# absent: it takes the UNREADABLE row under UNKNOWN LIMIT. A provider that just
# vanished from the dashboard would read as one fewer thing to worry about,
# which is the opposite of what a failed quota read means.
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
# section is "week", "day" or "unknown" - see the bucket rule below.
ROWS=

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
ROWS_PROGRAM=$(cat <<'JQ'
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
    # The row list is driven by the CONFIGURED providers joined against the
    # payload, never by the payload alone: a provider quota-axi omits still
    # owes the captain a row, and one that renders nowhere is indistinguishable
    # from a fleet that never had it. Each configured name appears once.
    ($providers | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $wanted |
    [ .providers[]? | select(((.provider // "") | tostring | length) > 0) ] as $entries |
    ($entries | map(.provider | tostring)) as $seen |
    ($entries + ([ $wanted[] | . as $w | select($seen | index($w) | not) ]
                 | unique | map({provider: .})))[] |
    (.provider | tostring) as $p | (.plan // "?") as $plan |
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
    elif $ok and $dispatch_provider and ($reported | length) > 0 then
      ["unknown", $p, $plan, "-", "unknown", ""]
    else ["unknown", $p, $plan, "-", "-1", ""] end)
    | map(tostring | if . == "" then "-" else . end) | @tsv
JQ
)

# <payload> <ok> -> the TSV rows, or a non-zero status when the payload cannot
# be walked at all. An empty object is a valid payload and yields exactly the
# per-provider unreadable rows, which is what makes it usable as the fallback.
quota_rows() {  # <payload> <ok>
  printf '%s' "$1" | jq -r --arg providers "$PROVIDERS" --argjson ok "$2" "$ROWS_PROGRAM" 2>/dev/null
}

collect() {
  local json img status ok rows
  json=$(quota-axi --provider "$PROVIDERS" --json 2>/dev/null)
  status=$?
  # The exit state is kept, not thrown away with the stderr: a run that failed
  # reported nothing we may read as complete, so a provider it did answer for
  # but without a dispatch window is unread rather than "not reported".
  ok=true
  [ "$status" -eq 0 ] || ok=false
  # The every-provider guarantee cannot live only inside the program a bad
  # payload breaks. A payload jq refuses to walk - unparseable, or provider
  # entries that are not objects - fails HERE and is answered by running the
  # same program over an empty one, so malformed output produces the identical
  # unreadable row per configured provider rather than an empty dashboard that
  # reads as a healthy fleet. Partial output from a failed run is discarded for
  # the complete set: half a fleet is the shape of the bug being closed.
  if ! rows=$(quota_rows "$json" "$ok") || [ -z "$rows" ]; then
    rows=$(quota_rows '{}' false)
  fi
  ROWS=$rows

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

# A window label is vendor prose and a provider name is whatever was asked
# for: both are unbounded, and an unbounded cell is what puts a line past the
# pane no matter how carefully the rest of the layout is measured. One owner
# cuts them to what the pane affords and marks the cut, so a long label costs
# its own tail instead of the alignment of every row around it.
ELIDE_MARK='~'
elide() {  # <text> <max>
  local text=$1 max=$2
  { [ "$max" -le 0 ] || [ "${#text}" -le "$max" ]; } && { printf '%s' "$text"; return; }
  printf '%s%s' "${text:0:$(( max > ${#ELIDE_MARK} ? max - ${#ELIDE_MARK} : 0 ))}" "$ELIDE_MARK"
}

# Caps for the two cells that carry that text, derived once per render from the
# pane. They are the COMPACT table's budget, because compact is the narrowest
# grid the dashboard draws: ID, REMAIN and the three separators cost 13
# columns, and MODEL is served first - a row that cannot say which provider it
# describes says nothing at all. A wide pane sets caps no real label reaches,
# so nothing is cut until the pane genuinely cannot pay for it.
CELL_MODEL_MAX=0 CELL_WIN_MAX=0
TABLE_FIXED=13
COLS=80

model_cell() {  # <provider>
  elide "$1" "$CELL_MODEL_MAX"
}

# Everything on a gauge line except the bar itself: "NN [" + " NNN.N%]" + " "
# + model + " (" + window + ")" plus any caveat - measured, not guessed, so the
# bar shrinks by exactly what the rest of the line needs instead of wrapping.
line_overhead() {  # <model> <window> <note>
  printf '%d' $(( 16 + ${#1} + ${#2} + $(caveat_width "$3") ))
}

# A gauge line budgets its window separately from the table's column: the table
# is a grid and must spend one width on every row, while a gauge line owes only
# itself. Sharing the table's cap would cut "Daily $0/$5" off the image row for
# columns a different row's long label wanted.
gauge_window() {  # <model> <window> <note>
  local max
  max=$(( COLS - 17 - ${#1} - $(caveat_width "$3") ))
  [ "$max" -ge 1 ] || max=1
  elide "$2" "$max"
}

# One bar width for the whole stack, taken from the LONGEST line in ROWS. A
# per-row width made two rows at the same percentage draw different bar
# lengths and knocked the numbers out of column - the gauges are read by
# comparing them, so equal percentages must look equal.
gauge_width() {  # <cols>
  local cols=$1 longest=0 overhead width sec prov plan win pct resets note model
  while IFS=$'\t' read -r sec prov plan win pct resets; do
    [ -n "$prov" ] || continue
    note=$(availability_note "$prov")
    model=$(model_cell "$prov")
    overhead=$(line_overhead "$model" "$(gauge_window "$model" "$win" "$note")" "$note")
    [ "$overhead" -le "$longest" ] || longest=$overhead
  done <<EOF
$ROWS
EOF
  width=$(( cols - longest ))
  # A floor wide enough to look like a bar is not worth a wrapped line: on a
  # pane that cannot spare the columns the bar gives them up, because the
  # percentage beside it is the number being read either way.
  [ "$width" -ge 1 ] || width=1
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

# A status row states a FACT and then offers HELP. "UNKNOWN - dispatch limit
# not reported" and "UNREADABLE" are the fact, and the caveat beside them is
# the uncertainty: neither may be dropped at any width. The command that would
# make an unreadable row readable is help, so that is what gives way when the
# pane cannot hold the line - and it is reprinted once at the bottom rather
# than lost, the same bargain the table makes when it goes compact.
UNREADABLE_FACT='UNREADABLE'
UNREADABLE_HELP='run: quota-axi --allow-keychain-prompt'
UNKNOWN_FACT='UNKNOWN - dispatch limit not reported'

# What a status row costs: "NN [" + text + "] " + provider + any caveat. The
# note is looked up from the provider as it was configured, never from the cell
# the row prints: a name cut to fit is still that provider's row.
status_width() {  # <text> <provider>
  local model
  model=$(model_cell "$2")
  printf '%d' $(( 6 + ${#1} + ${#model} + $(caveat_width "$(availability_note "$2")") ))
}

# True only for a percentage the dashboard may draw. "unknown" is a disclosure,
# and a negative percentage is the unreadable sentinel - neither is a number.
readable_pct() {  # <pct>
  [ "$1" != unknown ] || return 1
  awk -v p="$1" 'BEGIN { exit !(p >= 0) }'
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
  local want=$1 width=$2 help=$3
  local sec prov plan win pct resets note caveat text model
  _ANY=0
  while IFS=$'\t' read -r sec prov plan win pct resets; do
    [ -n "$prov" ] || continue
    row_in_section "$sec" "$want" || continue
    _ANY=1
    _ID=$(( _ID + 1 ))
    note=$(availability_note "$prov")
    caveat=$(caveat_suffix "$note")
    model=$(model_cell "$prov")
    if [ "$pct" = unknown ]; then
      printf '%s%2d%s [%s%s%s] %s%s%s%s\n' \
        "$CYAN" "$_ID" "$R" "$AMBER" "$UNKNOWN_FACT" "$R" "$B" "$model" "$R" "$caveat"
    elif ! readable_pct "$pct"; then
      text=$UNREADABLE_FACT
      [ "$help" -eq 0 ] || text="$UNREADABLE_FACT - $UNREADABLE_HELP"
      printf '%s%2d%s [%s%s%s] %s%s%s%s\n' \
        "$CYAN" "$_ID" "$R" "$AMBER" "$text" "$R" "$B" "$model" "$R" "$caveat"
    else
      gauge "$_ID" "$pct" "$model" "$(gauge_window "$model" "$win" "$note")" "$note" "$width"
    fi
  done <<EOF
$ROWS
EOF
  if [ "$_ANY" -eq 0 ]; then
    printf '%s  (none)%s\n' "$D" "$R"
  fi
}

# A row with no readable number carries no window and no reset either: those
# cells say "-" rather than borrowing a value the number cannot support.
window_text() {  # <window> <pct>
  if readable_pct "$2"; then printf '%s' "$1"; else printf '-'; fi
}

window_cell() {  # <window> <pct>
  elide "$(window_text "$1" "$2")" "$CELL_WIN_MAX"
}

note_cell() {  # <provider> <pct>
  local note
  note=$(availability_note "$1")
  [ "$2" = unknown ] || { printf '%s' "$note"; return; }
  case "$note" in
    -) printf 'dispatch limit not reported' ;;
    *) printf 'dispatch limit not reported; %s' "$note" ;;
  esac
}

# The ONE owner of the table's column joins. Every cell arrives padded to its
# measured width, so the header and the rows are laid out by the same code and
# cannot drift; compact simply drops the columns it cannot afford.
table_line() {  # <mode> <id> <model> <plan> <window> <remaining> <resets> <note>
  case "$1" in
    full)    printf '%s %s %s %s %s %s %s\n' "$2" "$3" "$4" "$5" "$6" "$7" "$8" ;;
    compact) printf '%s %s %s %s\n' "$2" "$3" "$5" "$6" ;;
  esac
}

# Column widths, measured once per render from the rows about to be drawn.
# REMAIN and RESETS are format-determined: "100.0%"/"unknown" and "1245d 12h"
# are the longest either can produce. The rest come from the data, because a
# fixed guess is what makes a table wrap the day a cell outgrows it.
TABLE_ID=3 TABLE_REM=7 TABLE_RESET=9 TABLE_NOTE_MIN=12
TABLE_MODEL=5 TABLE_PLAN=4 TABLE_WIN=6 TABLE_NOTE=12
DRAW_MODEL=5 DRAW_WIN=6

measure_table() {
  local sec prov plan win pct resets cell
  TABLE_MODEL=5 TABLE_PLAN=4 TABLE_WIN=6 TABLE_NOTE=$TABLE_NOTE_MIN
  while IFS=$'\t' read -r sec prov plan win pct resets; do
    [ -n "$prov" ] || continue
    [ "${#prov}" -le "$TABLE_MODEL" ] || TABLE_MODEL=${#prov}
    [ "${#plan}" -le "$TABLE_PLAN" ] || TABLE_PLAN=${#plan}
    cell=$(window_text "$win" "$pct")
    [ "${#cell}" -le "$TABLE_WIN" ] || TABLE_WIN=${#cell}
    cell=$(note_cell "$prov" "$pct")
    [ "${#cell}" -le "$TABLE_NOTE" ] || TABLE_NOTE=${#cell}
  done <<EOF
$ROWS
EOF
  # What the data asks for and what the pane can pay are two different numbers,
  # and each answers a different question. TABLE_* stays the natural width, so
  # "widen to N and the columns come back" keeps naming the width that really
  # restores them rather than one derived from the pane already too narrow.
  # DRAW_* is what the header and the rows are padded to - capped, so a label
  # the pane cannot afford loses its own tail instead of the grid's alignment.
  CELL_MODEL_MAX=$(( COLS - TABLE_FIXED - 1 ))
  [ "$CELL_MODEL_MAX" -ge 1 ] || CELL_MODEL_MAX=1
  DRAW_MODEL=$TABLE_MODEL
  [ "$DRAW_MODEL" -le "$CELL_MODEL_MAX" ] || DRAW_MODEL=$CELL_MODEL_MAX
  CELL_WIN_MAX=$(( COLS - TABLE_FIXED - DRAW_MODEL ))
  [ "$CELL_WIN_MAX" -ge 1 ] || CELL_WIN_MAX=1
  DRAW_WIN=$TABLE_WIN
  [ "$DRAW_WIN" -le "$CELL_WIN_MAX" ] || DRAW_WIN=$CELL_WIN_MAX
}

# What the full table costs, taken by rendering one of its lines at the
# measured widths rather than by re-adding the columns by hand - a second copy
# of the arithmetic is exactly how a layout change reintroduces wrapping.
#
# Called with TABLE_NOTE it gives the width the widest row needs; called with
# the AVAILABILITY label it gives the grid's own cost. The two differ because
# the note is the last cell and carries no padding: a note too long for the
# pane spills its own prose, while a grid too wide breaks every column.
table_width() {  # <note-width>
  local line
  line=$(table_line full \
    "$(printf '%*s'  "$TABLE_ID"    '')" \
    "$(printf '%-*s' "$TABLE_MODEL" '')" \
    "$(printf '%-*s' "$TABLE_PLAN"  '')" \
    "$(printf '%-*s' "$TABLE_WIN"   '')" \
    "$(printf '%*s'  "$TABLE_REM"   '')" \
    "$(printf '%-*s' "$TABLE_RESET" '')" \
    "$(printf '%-*s' "$1"           '')")
  printf '%d' "${#line}"
}

# The column the full table spends the most on, so a pane too narrow for it is
# told what it would have to fit rather than left to guess.
widest_column() {  # -> "<name> <width>"
  local name=AVAILABILITY w=$TABLE_NOTE
  [ "$TABLE_WIN"   -le "$w" ] || { name=WINDOW;    w=$TABLE_WIN; }
  [ "$TABLE_PLAN"  -le "$w" ] || { name=PLAN;      w=$TABLE_PLAN; }
  [ "$TABLE_MODEL" -le "$w" ] || { name=MODEL;     w=$TABLE_MODEL; }
  [ "$TABLE_RESET" -le "$w" ] || { name=RESETS;    w=$TABLE_RESET; }
  [ "$TABLE_REM"   -le "$w" ] || { name=REMAIN;    w=$TABLE_REM; }
  printf '%s %d' "$name" "$w"
}

# Print the detail table for one section. Restarts IDs from _ID_BASE so gauge
# and table IDs match within the section; continues the global sequence.
render_table() {
  local want=$1 table_mode=$2
  local sec prov plan win pct resets n win_cell rem_cell resets_cell note_cell
  n=$_ID_BASE
  _ANY=0
  printf '%s%s%s\n' "$HDR" "$(table_line "$table_mode" \
    "$(printf '%*s'  "$TABLE_ID"    ID)" \
    "$(printf '%-*s' "$DRAW_MODEL"  MODEL)" \
    "$(printf '%-*s' "$TABLE_PLAN"  PLAN)" \
    "$(printf '%-*s' "$DRAW_WIN"    WINDOW)" \
    "$(printf '%*s'  "$TABLE_REM"   REMAIN)" \
    "$(printf '%-*s' "$TABLE_RESET" RESETS)" \
    AVAILABILITY)" "$R"
  while IFS=$'\t' read -r sec prov plan win pct resets; do
    [ -n "$prov" ] || continue
    row_in_section "$sec" "$want" || continue
    _ANY=1
    n=$(( n + 1 ))
    win_cell=$(printf '%-*s' "$DRAW_WIN" "$(window_cell "$win" "$pct")")
    note_cell=$(note_cell "$prov" "$pct")
    resets_cell=$(printf '%-*s' "$TABLE_RESET" -)
    if [ "$pct" = unknown ]; then
      rem_cell=$(printf '%s%*s%s' "$AMBER" "$TABLE_REM" "unknown" "$R")
    elif ! readable_pct "$pct"; then
      rem_cell=$(printf '%s%*s%s' "$AMBER" "$TABLE_REM" "n/a" "$R")
    else
      rem_cell=$(printf '%s%*s%s' "$(tone_for "$pct")" "$TABLE_REM" "$(printf '%.1f%%' "$pct")" "$R")
      resets_cell=$(printf '%s%-*s%s' "$D" "$TABLE_RESET" "$(human_until "$resets")" "$R")
    fi
    table_line "$table_mode" \
      "$(printf '%s%*d%s' "$CYAN" "$TABLE_ID" "$n" "$R")" \
      "$(printf '%s%-*s%s' "$B" "$DRAW_MODEL" "$(model_cell "$prov")" "$R")" \
      "$(printf '%s%-*s%s' "$BLUE" "$TABLE_PLAN" "$plan" "$R")" \
      "$win_cell" "$rem_cell" "$resets_cell" "$note_cell"
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
  local cols table_mode total width needed grid wide_name wide_w sec prov pct help unread
  # COLUMNS wins when the environment states a width: tput reports the terminal
  # it can see, which is neither the caller's pane nor a stable value when the
  # dashboard is piped. Both agree in an ordinary interactive run.
  cols=${COLUMNS:-}
  case "$cols" in ''|*[!0-9]*|0) cols=$( { tput cols; } 2>/dev/null || echo 80) ;; esac
  case "$cols" in ''|*[!0-9]*|0) cols=80 ;; esac
  # The pane every cell is measured against. It is set before anything is
  # measured, because a width derived after the fact is a width the layout has
  # already spent.
  COLS=$cols
  # The mode is decided by what the table MEASURES, never by a constant: a
  # threshold below the layout's real cost picks a table that then wraps, which
  # is worse than the compact one it was meant to avoid. Compact is reserved
  # for a pane that cannot hold the grid at all - dropping PLAN, RESETS and
  # AVAILABILITY from every row because one row's note is long would cost the
  # captain more than that note spilling does.
  measure_table
  needed=$(table_width "$TABLE_NOTE")
  grid=$(table_width "$TABLE_NOTE_MIN")
  if [ "$cols" -ge "$grid" ]; then table_mode=full
  else                             table_mode=compact
  fi
  width=$(gauge_width "$cols")

  # The status rows are measured like everything else, and the answer is one
  # answer for the whole stack: two providers in the same state that printed
  # different text would read as two different states.
  total=0
  help=1
  unread=0
  while IFS=$'\t' read -r sec prov _ _ pct _; do
    [ -n "$prov" ] || continue
    total=$(( total + 1 ))
    if [ "$pct" != unknown ] && ! readable_pct "$pct"; then
      unread=1
      [ "$(status_width "$UNREADABLE_FACT - $UNREADABLE_HELP" "$prov")" -le "$cols" ] || help=0
    fi
  done <<EOF
$ROWS
EOF

  _ID=0
  section_title "WEEKLY LIMIT"
  render_gauges week "$width" "$help"
  printf '\n'
  _ID_BASE=0
  render_table week "$table_mode"
  printf '\n'

  _ID_BASE=$_ID
  section_title "DAILY LIMIT"
  render_gauges day "$width" "$help"
  printf '\n'
  render_table day "$table_mode"
  printf '\n'

  # Last, and only when something landed there: an unmeasured row must not push
  # an actionable limit down the screen, and an empty heading would be noise on
  # a fleet whose windows all came back with a cycle.
  if section_has_rows unknown; then
    _ID_BASE=$_ID
    section_title "UNKNOWN LIMIT"
    render_gauges unknown "$width" "$help"
    printf '\n'
    render_table unknown "$table_mode"
    printf '\n'
  fi

  # Whenever the pane is short of the full table - whether that cost it the
  # grid or only the tail of a note - it is told the measurement and the column
  # that drove it, so a narrower reading is never an unexplained one.
  #
  # A pane that LOST columns is told the width that brings them back, which is
  # the grid's - not the wider one a note needs to stop spilling. Naming the
  # spill width there sends the captain looking for columns the dropped ones
  # never cost. The spill width is still disclosed, on its own line, so the two
  # measurements cannot be read as one number.
  if [ "$cols" -lt "$needed" ]; then
    read -r wide_name wide_w <<EOF
$(widest_column)
EOF
    if [ "$table_mode" = compact ]; then
      printf '%s  PLAN/RESETS/AVAILABILITY return at %d cols%s\n' "$D" "$grid" "$R"
    fi
    if [ "$table_mode" != compact ] || [ "$needed" -gt "$grid" ]; then
      printf '%s  full table needs %d cols (%s %d)%s\n' "$D" "$needed" "$wide_name" "$wide_w" "$R"
    fi
  fi

  # The remedy a status row could not carry is printed once here instead, so
  # the pane that was too narrow for it loses the repetition, not the help.
  if [ "$unread" -eq 1 ] && [ "$help" -eq 0 ]; then
    printf '%s  unreadable: %s%s\n' "$D" "$UNREADABLE_HELP" "$R"
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
