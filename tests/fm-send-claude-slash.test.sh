#!/usr/bin/env bash
# fm-send claude slash-command submit verification (the false "Enter swallowed").
#
# Incident (docs/tmux-backend.md "Incident (2026-07-09)"): claude 2.x renders
# its unbordered composer prompt row as "❯" + U+00A0 (a no-break space), which
# [:space:] trimming never strips. fm_tmux_composer_state therefore classified
# claude's idle/submitted composer row as "pending" forever, so fm-send's
# submit verification false-errored "Enter swallowed" on nearly every send -
# most visibly on every /no-mistakes slash command - even though the text had
# landed. The normalization itself lives in the shared classifier
# (fm_composer_classify_content, bin/fm-composer-lib.sh; unit-covered in
# fm-composer-lib.test.sh); these tests pin the tmux path end-to-end,
# hermetically, with a fake tmux whose rows are byte-for-byte the shapes
# captured from the live claude pane:
#   1. fm_tmux_composer_state: "❯" + NBSP (idle, and the gray post-submit
#      rendering) reads empty; "❯" + NBSP + typed text reads pending.
#   2. fm-send: a slash command whose Enter lands reports success - no false
#      "Enter swallowed" error.
#   3. fm-send: a slash command whose first Enter is swallowed is retried
#      (Enter only, never retyped) and succeeds once the retry lands.
#   4. fm-send: a genuinely-unsubmitted composer (every Enter swallowed) still
#      reports the real failure, non-zero, with the "Enter swallowed" error.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-claude-slash)

# A fake tmux that renders claude 2.x's composer shapes (verified live against
# real claude 2.1.204 under tmux 3.6b):
#   idle/submitted row - "❯" + NBSP, gray-colored after a submit
#   typed row          - "❯" + NBSP + the typed text in a color run
# send-keys -l records the text and puts it in the composer; Enter submits
# (clears the composer back to the idle row) unless FM_FAKE_SWALLOW names an
# existing file, which swallows that Enter (one-shot, or every time with
# FM_FAKE_PERSIST_SWALLOW=1).
make_claude_fake() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  # Idle claude composer: plain "❯" + NBSP.
  printf '\342\235\257\302\240\n' > "$dir/composer"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    for a in "$@"; do [ "$a" = "-p" ] && { printf 'fakepane\n'; break; }; done
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        # Submitted: the gray "❯" + NBSP row claude renders during the turn.
        printf '\033[38;5;246m\342\235\257\302\240\033[39m\n' > "$COMPOSER"
      fi
    elif [ "$lit" = 1 ]; then
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      # Typed: "❯" + NBSP + the text in claude's input color run.
      printf '\342\235\257\302\240\033[38;5;153m%s\033[39m\n' "$text" > "$COMPOSER"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# run_send <dir> <fakebin> [env-assignments...] -- exit code is fm-send's.
# Stderr lands in <dir>/stderr for the error-message assertions.
run_send() {
  local dir=$1 fb=$2 home; shift 2
  home="$dir/home"; mkdir -p "$home/state"
  env "$@" PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$dir/sent.log" \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0.01 FM_SEND_SETTLE=0 \
    "$SEND" "sess:win" "/no-mistakes" 2> "$dir/stderr"
}

# --- fm_tmux_composer_state on the live-captured claude row shapes -----------

test_composer_state_claude_nbsp_rows() {
  local dir fb out
  dir="$TMP_ROOT/state-unit"; mkdir -p "$dir"
  fb=$(make_claude_fake "$dir")
  # Idle: plain "❯" + NBSP.
  printf '\342\235\257\302\240\n' > "$dir/composer"
  out=$(PATH="$fb:$PATH" FM_FAKE_COMPOSER="$dir/composer" fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "idle '❯' + NBSP row should read empty, got '$out'"
  # Post-submit: the same row in claude's gray color run.
  printf '\033[38;5;246m\342\235\257\302\240\033[39m\n' > "$dir/composer"
  out=$(PATH="$fb:$PATH" FM_FAKE_COMPOSER="$dir/composer" fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "gray post-submit '❯' + NBSP row should read empty, got '$out'"
  # Typed slash command (popup open): real text after the NBSP.
  printf '\342\235\257\302\240\033[38;5;153m/no-mistakes\033[39m\n' > "$dir/composer"
  out=$(PATH="$fb:$PATH" FM_FAKE_COMPOSER="$dir/composer" fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] || fail "typed '/no-mistakes' after the NBSP prompt should read pending, got '$out'"
  pass "fm_tmux_composer_state: claude NBSP prompt rows read empty when bare, pending with typed text"
}

# --- fm-send: slash command that landed reports success ----------------------

test_slash_command_landed_no_false_error() {
  local dir fb rc
  dir="$TMP_ROOT/landed"; mkdir -p "$dir"
  fb=$(make_claude_fake "$dir")
  run_send "$dir" "$fb"; rc=$?
  expect_code 0 "$rc" "a landed slash command must report success"
  if grep -q "Enter swallowed" "$dir/stderr"; then
    fail "a landed slash command still emitted the false 'Enter swallowed' error:"$'\n'"$(cat "$dir/stderr")"
  fi
  grep -qx '/no-mistakes' "$dir/sent.log" || fail "the slash command text was not typed"
  [ "$(grep -cx '\[ENTER\]' "$dir/sent.log")" = 1 ] || fail "expected exactly one submitting Enter, got: $(cat "$dir/sent.log")"
  pass "fm-send: a slash command that landed reports success with no false 'Enter swallowed' error"
}

# --- fm-send: a swallowed Enter is retried, then succeeds --------------------

test_slash_command_swallowed_once_retried() {
  local dir fb rc
  dir="$TMP_ROOT/swallow-once"; mkdir -p "$dir"
  fb=$(make_claude_fake "$dir")
  : > "$dir/swallow"
  run_send "$dir" "$fb" FM_FAKE_SWALLOW="$dir/swallow"; rc=$?
  expect_code 0 "$rc" "a retried Enter that lands must report success"
  if grep -q "Enter swallowed" "$dir/stderr"; then
    fail "a successful retry still emitted the 'Enter swallowed' error:"$'\n'"$(cat "$dir/stderr")"
  fi
  # The text is typed exactly once (Enter is retried, never the text).
  [ "$(grep -cx '/no-mistakes' "$dir/sent.log")" = 1 ] || fail "the text was retyped on retry: $(cat "$dir/sent.log")"
  pass "fm-send: a swallowed Enter is retried (never retyped) and the landed retry reports success"
}

# --- fm-send: a genuinely-unsubmitted composer still fails loudly ------------

test_slash_command_never_submitted_real_failure() {
  local dir fb rc
  dir="$TMP_ROOT/swallow-all"; mkdir -p "$dir"
  fb=$(make_claude_fake "$dir")
  : > "$dir/swallow"
  run_send "$dir" "$fb" FM_FAKE_SWALLOW="$dir/swallow" FM_FAKE_PERSIST_SWALLOW=1; rc=$?
  [ "$rc" -ne 0 ] || fail "a never-submitted slash command must exit non-zero"
  grep -q "Enter swallowed" "$dir/stderr" || fail "the real swallow did not report the 'Enter swallowed' error:"$'\n'"$(cat "$dir/stderr")"
  pass "fm-send: a genuinely-unsubmitted composer still exits non-zero with the real 'Enter swallowed' error"
}

test_composer_state_claude_nbsp_rows
test_slash_command_landed_no_false_error
test_slash_command_swallowed_once_retried
test_slash_command_never_submitted_real_failure
