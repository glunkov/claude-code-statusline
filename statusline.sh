#!/bin/bash
# Statusline for Claude Code: left/center/right zones + adaptive wrapping.
#   Left:   [Model] · 💰 cost · ⏱ session
#   Center: 🧠 context · ⚡5h limit · 📅7d limit
#   Right:  🌿 branch
# Reads ONLY stdin (JSON from Claude Code). No network, no credential access.

input=$(cat)

# Colors.
GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; CYAN='\033[36m'; DIM='\033[2m'; RESET='\033[0m'
SEP=" ${DIM}·${RESET} "

COLS=${COLUMNS:-120}     # width is provided by Claude Code (v2.1.153+).
{ [[ $COLS =~ ^[0-9]+$ ]] && [ "$COLS" -ge 20 ]; } || COLS=120   # bogus/zero/too-small COLUMNS → fall back (also blocks arithmetic injection).
RMARGIN=2                # right margin: CC notifications share the right edge.

# Repeat spaces n times (guards against negative).
rep() { local n=$1; [ "$n" -lt 0 ] && n=0; printf '%*s' "$n" ''; }

# Visible width of a string: strip ANSI (literal \033[..m), then count code points
# + correct for wide emoji (each renders as 2 columns but is 1 character).
vislen() {
  # Strip BOTH ANSI forms: a real ESC byte (from printf '%b', e.g. bar colors)
  # and the literal "\033" string (from variables used directly). Missing the
  # real-ESC form makes vislen over-count and shoves the right zone leftward.
  local esc=$'\033'
  local clean=$(printf '%s' "$1" | sed -E "s/($esc|\\\\033)\[[0-9;]*m//g")
  local w=${#clean} e t
  for e in 🧠 💰 🌿 ⚡ 📅 ⏱; do
    t=${clean//$e/}
    w=$((w + ${#clean} - ${#t}))
  done
  printf '%s' "$w"
}

# Color by proximity to max: <70 green, 70-89 yellow, 90+ red.
pct_color() {
  if   [ "$1" -ge 90 ]; then printf '%b' "$RED"
  elif [ "$1" -ge 70 ]; then printf '%b' "$YELLOW"
  else printf '%b' "$GREEN"; fi
}

# Bar of width 10: bar <percent> (filled).
bar() {
  local pct=$1 filled empty fill pad
  [ "$pct" -gt 100 ] && pct=100; [ "$pct" -lt 0 ] && pct=0
  filled=$((pct / 10)); empty=$((10 - filled)); fill=""; pad=""
  [ "$filled" -gt 0 ] && printf -v fill "%${filled}s"
  [ "$empty"  -gt 0 ] && printf -v pad  "%${empty}s"
  printf '%s%s' "${fill// /▓}" "${pad// /░}"
}

# Seconds → countdown to limit reset.
fmt_left() {
  local s=$1 d h m; [ "$s" -lt 0 ] && s=0
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# Seconds → session duration.
fmt_dur() {
  local s=$1 h m sec; h=$((s / 3600)); m=$(((s % 3600) / 60)); sec=$((s % 60))
  if   [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm %ds' "$m" "$sec"
  else printf '%ds' "$sec"; fi
}

NOW=$(date +%s)

# ---- LEFT: model · cost · session ----
# Strip control chars and backslashes (and cap length) so a hostile display_name
# can't inject terminal escape sequences through `echo -e` below.
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"' | tr -d '\000-\037\\' | cut -c1-40)
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
DUR_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0' | grep -Eo '^[0-9]+' || echo 0)
LEFT="${CYAN}[$MODEL]${RESET}${SEP}💰 $(printf '$%.2f' "$COST")${SEP}⏱ session $(fmt_dur $((DUR_MS / 1000)))"

# ---- CENTER: context · 5h · 7d ----
CTX_USED=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | grep -Eo '^[0-9]+' || echo 0)
CTX_FREE=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty' | grep -Eo '^[0-9]+' || true)
[ -z "$CTX_FREE" ] && CTX_FREE=$((100 - CTX_USED))
CC=$(pct_color "$CTX_USED")
CENTER="🧠 ${CC}$(bar "$CTX_FREE")${RESET} ${CTX_FREE}% free"

FIVE=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | grep -Eo '^[0-9]+([.][0-9]+)?' || true)
FIVE_R=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' | grep -Eo '^[0-9]+' || true)
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | grep -Eo '^[0-9]+([.][0-9]+)?' || true)
WEEK_R=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' | grep -Eo '^[0-9]+' || true)
if [ -n "$FIVE" ]; then
  P=$(printf '%.0f' "$FIVE"); C=$(pct_color "$P")
  SEG="⚡5h ${C}$(bar "$P") ${P}%${RESET}"
  [ -n "$FIVE_R" ] && SEG="$SEG ${DIM}↻ $(fmt_left $((FIVE_R - NOW)))${RESET}"
  CENTER="$CENTER$SEP$SEG"
fi
if [ -n "$WEEK" ]; then
  P=$(printf '%.0f' "$WEEK"); C=$(pct_color "$P")
  SEG="📅7d ${C}$(bar "$P") ${P}%${RESET}"
  [ -n "$WEEK_R" ] && SEG="$SEG ${DIM}↻ $(fmt_left $((WEEK_R - NOW)))${RESET}"
  CENTER="$CENTER$SEP$SEG"
fi

# ---- RIGHT: branch ----
BFULL=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  BFULL=$(git branch --show-current 2>/dev/null | tr -d '\000-\037\\')
fi

MAXBR=28   # hard cap on the branch zone width in columns (incl. "🌿 " and "…").

# Render RIGHT from the full branch name, truncated to at most <maxcols> visible columns.
set_branch() {
  local maxcols=$1 keep
  [ -z "$BFULL" ] && { RIGHT=""; WR=0; return; }
  if [ $(( ${#BFULL} + 3 )) -le "$maxcols" ]; then
    RIGHT="${DIM}🌿 ${BFULL}${RESET}"
  else
    keep=$(( maxcols - 4 ))        # "🌿 " (3 cols) + "…" (1 col)
    [ "$keep" -lt 1 ] && keep=1
    RIGHT="${DIM}🌿 ${BFULL:0:$keep}…${RESET}"
  fi
  WR=$(vislen "$RIGHT")
}

set_branch "$MAXBR"   # global cap: a long branch never dominates the line.

AVAIL=$((COLS - RMARGIN))
WL=$(vislen "$LEFT"); WC=$(vislen "$CENTER")

# Attempt 1: single line — left on the left, branch on the right, limits centered in
# the AVAILABLE field (the gap between the left zone and the branch).
GAP=$(( AVAIL - WL - WR ))
if [ "$GAP" -ge $(( WC + 2 )) ]; then
  INNER=$(( GAP - WC )); P1=$(( INNER / 2 )); P2=$(( INNER - P1 ))
  echo -e "${LEFT}$(rep $P1)${CENTER}$(rep $P2)${RIGHT}"
  exit 0
fi

# Attempt 2 (narrow screen): two lines.
#   line 1: model/cost on the left + branch on the right
#   line 2: limits centered
# Two-line mode: cap the branch to the smaller of MAXBR and the room left of it.
budget=$(( AVAIL - WL - 1 ))
[ "$budget" -gt "$MAXBR" ] && budget=$MAXBR
set_branch "$budget"
LINE1="$LEFT"
if [ -n "$RIGHT" ]; then
  LINE1="${LEFT}$(rep $(( AVAIL - WL - WR )))${RIGHT}"
fi
echo -e "$LINE1"
echo -e "$(rep $(( (AVAIL - WC) / 2 )) )${CENTER}"
