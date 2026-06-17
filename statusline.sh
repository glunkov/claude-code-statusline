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
WAIT='⏳'                 # placeholder shown in a limit's number slot until its data arrives.

COLS=${COLUMNS:-120}     # width is provided by Claude Code (v2.1.153+).
{ [[ $COLS =~ ^[0-9]+$ ]] && [ "$COLS" -ge 20 ]; } || COLS=120   # bogus/zero/too-small COLUMNS → fall back (also blocks arithmetic injection).
RMARGIN=6                # right-edge cushion: keeps the line clear of the real terminal edge so
                         # vislen's small per-glyph under-count can't overflow and get truncated.

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
  for e in 🧠 💰 🌿 ⚡ 📅 ⏱ ⏳; do
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
FIVE=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | grep -Eo '^[0-9]+([.][0-9]+)?' || true)
FIVE_R=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' | grep -Eo '^[0-9]+' || true)
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | grep -Eo '^[0-9]+([.][0-9]+)?' || true)
WEEK_R=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' | grep -Eo '^[0-9]+' || true)

# Build the CENTER block at a compaction level (sets $CENTER). Higher level = narrower:
#   0 = bar + % + ↻ reset countdown   (full)
#   1 = bar + %                        (drop countdowns)
#   2 = % only                         (drop bars)
#   3 = colored severity dot only      (very narrow windows: ● green/yellow/red)
build_center() {
  local level=$1 c p seg
  c=$(pct_color "$CTX_USED")
  case "$level" in
    0|1) CENTER="🧠 ${c}$(bar "$CTX_FREE")${RESET} ${CTX_FREE}% free" ;;
    2)   CENTER="🧠 ${c}${CTX_FREE}% free${RESET}" ;;
    *)   CENTER="🧠 ${c}●${RESET}" ;;
  esac
  # Each rate-limit segment renders even before its data arrives: an inactive gray slider plus a
  # waiting marker keeps the layout from jumping when the 5h/7d numbers appear after the first API
  # response. $1=emoji $2=label $3=raw pct (may be empty) $4=resets_at (may be empty).
  limit_seg() {
    local emoji=$1 label=$2 raw=$3 rat=$4 p c seg
    if [ -n "$raw" ]; then
      p=$(printf '%.0f' "$raw"); c=$(pct_color "$p")
      case "$level" in
        0|1) seg="$emoji$label ${c}$(bar "$p") ${p}%${RESET}" ;;
        2)   seg="$emoji$label ${c}${p}%${RESET}" ;;
        *)   seg="$emoji${c}●${RESET}" ;;
      esac
      [ "$level" -eq 0 ] && [ -n "$rat" ] && seg="$seg ${DIM}↻ $(fmt_left $((rat - NOW)))${RESET}"
    else
      case "$level" in
        0|1) seg="$emoji$label ${DIM}$(bar 0) ${WAIT}${RESET}" ;;   # gray empty slider + waiting marker
        2)   seg="$emoji$label ${DIM}${WAIT}${RESET}" ;;
        *)   seg="$emoji${DIM}●${RESET}" ;;
      esac
    fi
    CENTER="$CENTER$SEP$seg"
  }
  limit_seg "⚡" "5h" "$FIVE" "$FIVE_R"
  limit_seg "📅" "7d" "$WEEK" "$WEEK_R"
}

# ---- RIGHT: branch ----
BFULL=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  BFULL=$(git branch --show-current 2>/dev/null | tr -d '\000-\037\\')
fi

MAXBR=40   # hard cap on the branch zone width in columns (incl. "🌿 " and "…").

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
WL=$(vislen "$LEFT")

# Attempt 1: single line — left zone, limits, branch laid out left-to-right.
# Rules:
#   • Left gap is FIXED at PAD1 → the center block stays at the same position regardless of branch
#     length (the look the user tuned at full size).
#   • The branch is flush-right, so the right gap is the remainder (PAD1 + PAD2 reference is 55:95)
#     and SHRINKS on its own as the branch name grows.
#   • Windowed: once the window is too narrow to afford the fixed PAD1, the left gap scales down
#     proportionally (keeping the 55:95 lean) instead of dropping straight to two lines.
PAD1=55    # reference left gap:  left zone → center.
PAD2=95    # reference right gap: center → branch (also sets the windowed scaling ratio).
MINGAP=3   # smallest right gap before the left pad must give way.
build_center 0
WC=$(vislen "$CENTER")
GAP=$(( AVAIL - WL - WR ))
if [ "$GAP" -ge $(( WC + 2 )) ]; then
  gaps=$(( GAP - WC ))                   # total free space = P1 + P2 (branch flush right).
  if [ "$gaps" -ge $(( PAD1 + MINGAP )) ]; then
    P1=$PAD1                             # enough room → fixed left pad; center stays put.
  else
    P1=$(( gaps * PAD1 / (PAD1 + PAD2) ))   # windowed → scale the left pad down, keep the 55:95 lean.
    [ "$P1" -lt 2 ] && P1=2
  fi
  P2=$(( gaps - P1 ))                     # right pad takes the rest; shrinks as the branch grows.
  echo -e "${LEFT}$(rep $P1)${CENTER}$(rep $P2)${RIGHT}"
  exit 0
fi

# Attempt 2 (narrow screen): two lines.
#   line 1: model/cost on the left + branch on the right
#   line 2: limits, left-aligned, collapsed to the most detailed tier that fits.
for lvl in 0 1 2 3; do
  build_center "$lvl"
  WC=$(vislen "$CENTER")
  [ "$WC" -le "$AVAIL" ] && break
done
room=$(( AVAIL - WL ))                 # columns left of the right edge after the left zone
budget=$(( room - 1 ))                 # prefer a 1-column gap before the branch
[ "$budget" -gt "$MAXBR" ] && budget=$MAXBR
set_branch "$budget"
# If the 1-column gap forced truncation but the full branch fits flush, show it full.
if [ -n "$BFULL" ] && [ $(( ${#BFULL} + 3 )) -gt "$budget" ] && [ $(( ${#BFULL} + 3 )) -le "$room" ]; then
  set_branch "$room"
fi
LINE1="$LEFT"
if [ -n "$RIGHT" ] && [ "$WR" -le "$room" ]; then
  LINE1="${LEFT}$(rep $(( room - WR )))${RIGHT}"
fi
echo -e "$LINE1"
echo -e "$CENTER"                      # limits left-aligned, directly under the left zone
