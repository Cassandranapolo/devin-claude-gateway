#!/usr/bin/env bash
# scripts/_lib.sh — shared helpers sourced by other scripts.
#
# Provides:
#   color/info/warn/err/ok/step          : pretty terminal logging
#   escape_dollar <string>                : escape $ -> $$ for docker compose
#   env_set <file> <key> <value>          : safely upsert KEY=value in .env
#   env_unset <file> <key>                : remove KEY=... line from .env
#   env_get <file> <key>                  : print value of KEY (no key= prefix)
#   require_cmd <cmd> [hint]              : exit 1 if command not found
#   require_file <path> [hint]            : exit 1 if file missing
#   confirm <prompt>                      : yes/no prompt, default yes

# Bail out if sourced twice.
if [[ -n "${_DEVIN_GW_LIB_LOADED:-}" ]]; then
  return 0
fi
_DEVIN_GW_LIB_LOADED=1

# ---------- pretty logging ---------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  _C_RESET=$'\033[0m'
  _C_BOLD=$'\033[1m'
  _C_CYAN=$'\033[1;36m'
  _C_GREEN=$'\033[1;32m'
  _C_YELLOW=$'\033[1;33m'
  _C_RED=$'\033[1;31m'
  _C_GREY=$'\033[1;30m'
else
  _C_RESET=''
  _C_BOLD=''
  _C_CYAN=''
  _C_GREEN=''
  _C_YELLOW=''
  _C_RED=''
  _C_GREY=''
fi

info() { printf '%s[info]%s %s\n'  "$_C_CYAN"   "$_C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n'  "$_C_YELLOW" "$_C_RESET" "$*"; }
err()  { printf '%s[error]%s %s\n' "$_C_RED"    "$_C_RESET" "$*" 1>&2; }
ok()   { printf '%s[ok]%s %s\n'    "$_C_GREEN"  "$_C_RESET" "$*"; }

# step <n> <total> <msg>   -> "[3/5] msg"
step() {
  local n="$1" total="$2"; shift 2
  printf '%s[%s/%s]%s %s\n' "$_C_BOLD" "$n" "$total" "$_C_RESET" "$*"
}

# hint <msg>  -> grey indented hint, used after errors
hint() { printf '%s       %s%s\n' "$_C_GREY" "$*" "$_C_RESET"; }

# ---------- string helpers ---------------------------------------------------

# escape_dollar <string>
# docker-compose interpolates ${VAR} and $VAR in env_file values, so any literal
# '$' in cookies (especially _ga_* values like "GS2.1.s.....$o2$g1$t...") must
# be escaped to '$$' before being written to .env. This function prints the
# escaped value on stdout.
escape_dollar() {
  printf '%s' "${1//\$/\$\$}"
}

# ---------- .env helpers -----------------------------------------------------

# env_set <file> <key> <raw_value>
#
# Upserts "<key>=<value>" in the given env file, replacing the first matching
# line or appending if missing. The value is written as-is — call escape_dollar
# yourself first if the value may contain '$' (e.g. cookies).
env_set() {
  local file="$1" key="$2" value="$3"
  if [[ ! -f "$file" ]]; then
    : > "$file"
  fi
  # awk is used instead of sed so the value can safely contain '|', '/', etc.
  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v val="$value" '
    BEGIN { done = 0 }
    {
      if (!done && index($0, key "=") == 1) {
        print key "=" val
        done = 1
        next
      }
      print
    }
    END { if (!done) print key "=" val }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

env_unset() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$file" > "$tmp" || true
  mv "$tmp" "$file"
}

env_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

# ---------- pre-flight -------------------------------------------------------

require_cmd() {
  local cmd="$1" hint_msg="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "command \"$cmd\" tidak ditemukan di PATH."
    [[ -n "$hint_msg" ]] && hint "$hint_msg"
    exit 1
  fi
}

require_file() {
  local path="$1" hint_msg="${2:-}"
  if [[ ! -f "$path" ]]; then
    err "file \"$path\" tidak ditemukan."
    [[ -n "$hint_msg" ]] && hint "$hint_msg"
    exit 1
  fi
}

# confirm "Lanjut?" [default=Y]
confirm() {
  local prompt="$1" default="${2:-Y}"
  local hint_str
  if [[ "$default" =~ ^[Yy]$ ]]; then
    hint_str="(Y/n)"
  else
    hint_str="(y/N)"
  fi
  local answer
  read -rp "$prompt $hint_str " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}
