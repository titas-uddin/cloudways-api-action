#!/usr/bin/env bash
# Cloudways API call with Access Token (Bearer) auth.
# Inputs come from env vars set by action.yml (CW_*).
set -euo pipefail

: "${CW_TOKEN:?access-token is required}"
: "${CW_PATH:?api-path is required}"

METHOD="$(echo "${CW_METHOD:-POST}" | tr '[:lower:]' '[:upper:]')"
BASE="${CW_BASE_URL:-https://api.cloudways.com/api}"
BASE="${BASE%/}/${CW_API_VERSION:-v2}"
if [[ ! "$BASE" =~ ^https:// && ! "$BASE" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?/ ]]; then
  echo "::error::api-base-url must start with https:// (http:// is only allowed for localhost)"
  exit 1
fi
PREFIX="${CW_PREFIX:-cw_}"
WAIT="${CW_WAIT:-false}"
OP_TIMEOUT="${CW_OP_TIMEOUT:-300}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_ENV="${GITHUB_ENV:-/dev/null}"

echo "::add-mask::$CW_TOKEN"

TMPD="$(mktemp -d -p "${RUNNER_TEMP:-/tmp}")"
trap 'rm -rf "$TMPD"' EXIT

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# make untrusted text safe inside a workflow command (::error:: etc.): single line, % escaped
oneline() { tr -d '\r' | tr '\n' ' ' | sed 's/%/%25/g'; }

# write a (possibly multiline) value to $GITHUB_OUTPUT / $GITHUB_ENV
emit() { # file name value
  local delim="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  { echo "$2<<$delim"; echo "$3"; echo "$delim"; } >> "$1"
}

# ---------- build request params ----------
# GET (or request-format: form) -> url-encoded params, "key[]" repeated per item.
# Otherwise -> JSON body like the old RafinBiswas action: "key[]:a,b" becomes
# {"key":["a","b"]}, and values that parse as JSON (numbers, true, [..]) are sent as JSON.
FORMAT="$(echo "${CW_FORMAT:-json}" | tr '[:upper:]' '[:lower:]')"
[ "$METHOD" = "GET" ] && FORMAT=form
ARGS=()
JSON='{}'
while IFS= read -r line || [ -n "$line" ]; do
  line="$(trim "$line")"
  [ -z "$line" ] && continue
  [[ "$line" == \#* ]] && continue
  if [[ "$line" != *:* ]]; then
    echo "::error::request-body line without ':' (expected key:value)"
    exit 1
  fi
  key="$(trim "${line%%:*}")"
  val="$(trim "${line#*:}")"
  if [ "$FORMAT" = "json" ]; then
    if [[ "$key" == *"[]" ]]; then
      JSON="$(jq -c --arg k "${key%[]}" --arg v "$val" \
        '.[$k] = ($v | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))' <<< "$JSON")"
    else
      JSON="$(jq -c --arg k "$key" --arg v "$val" '.[$k] = ($v | try fromjson catch $v)' <<< "$JSON")"
    fi
  elif [[ "$key" == *"[]" ]]; then
    IFS=',' read -ra parts <<< "$val"
    for p in "${parts[@]}"; do
      p="$(trim "$p")"
      [ -n "$p" ] && ARGS+=(--data-urlencode "$key=$p")
    done
  else
    ARGS+=(--data-urlencode "$key=$val")
  fi
done <<< "${CW_BODY:-}"
[ "$FORMAT" = "json" ] && ARGS=(-H "Content-Type: application/json" --data "$JSON")

# ---------- HTTP call ----------
AUTH_ESC="${CW_TOKEN//\\/\\\\}"; AUTH_ESC="${AUTH_ESC//\"/\\\"}"   # escape \ and " for curl's config syntax
CODE_FILE="$TMPD/code"
call() { # method path [curl args...]  -> body on stdout; LVL=warning softens failures, NOBODY=1 hides bodies
  local m="$1" p="$2"; shift 2
  local lvl="${LVL:-error}" body
  body() { [ -n "${NOBODY:-}" ] && echo "(body hidden)" || head -c 2000 "$1" | oneline; }
  local out code
  out="$(mktemp -p "$TMPD")"
  local extra=()
  [ "$m" = "GET" ] && extra=(-G)
  # the Authorization header goes in via stdin (-K -), so the token never shows in the process list
  code=$(curl -sS --retry 3 --retry-delay 3 --retry-connrefused -K - \
    -o "$out" -w '%{http_code}' -X "$m" "${extra[@]}" \
    -H "Accept: application/json" \
    "$@" "$BASE$p" <<< "header = \"Authorization: Bearer $AUTH_ESC\"") \
    || { echo "::$lvl::Request failed: $m $p (network error)" >&2; rm -f "$out"; return 1; }
  echo "$code" > "$CODE_FILE"
  if [ "$code" -ge 400 ]; then
    case "$code" in
      401) hint=" (token wrong, expired or revoked)";;
      403) hint=" (token scope does not allow this endpoint)";;
      404|410) hint=" (endpoint or API version not available; check api-path / api-version)";;
      *) hint="";;
    esac
    echo "::$lvl::Cloudways $m $p -> HTTP $code$hint: $(body "$out")" >&2
    rm -f "$out"
    return 1
  fi
  if jq -e 'type == "object" and (.status == false or (.data | type == "object" and .status == false))' "$out" >/dev/null 2>&1; then
    echo "::$lvl::Cloudways $m $p returned status=false: $(body "$out")" >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

echo "Cloudways $METHOD $CW_PATH ($BASE)"
RESP="$(call "$METHOD" "$CW_PATH" "${ARGS[@]}")"
CODE="$(cat "$CODE_FILE")"
echo "HTTP $CODE"

emit "$GITHUB_OUTPUT" response "$RESP"
echo "http-code=$CODE" >> "$GITHUB_OUTPUT"

IS_JSON=false
echo "$RESP" | jq -e . >/dev/null 2>&1 && IS_JSON=true

# ---------- export response values to env ----------
while IFS= read -r line || [ -n "$line" ]; do
  line="$(trim "$line")"
  [ -z "$line" ] && continue
  [[ "$line" == \#* ]] && continue
  path="$(trim "${line%%:*}")"
  default=""
  [[ "$line" == *:* ]] && default="$(trim "${line#*:}")"
  name="${PREFIX}$(echo "$path" | sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+|_+$//g')"

  if [ "$IS_JSON" != true ]; then
    echo "::warning::Response is not JSON; exporting default for $name"
    value="$default"; [ "$value" = "[]" ] && value=""
  else
    value="$(echo "$RESP" | jq -r --arg p "$path" --arg d "$default" '
      (if type == "object" and has("data") then . else {data: .} end)
      | (try getpath($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end)) catch null) as $v
      | (if ($v | type) == "string" and ($v | test("^\\s*[\\[{]")) then (try ($v | fromjson) catch $v) else $v end) as $v
      | if $v == null then (if $d == "[]" or $d == "{}" then "" else $d end)
        elif ($v | type) == "array" then $v | map(if type == "string" then . else tojson end) | join(",")
        elif ($v | type) == "object" then $v | tojson
        else $v | tostring end')"
  fi
  emit "$GITHUB_ENV" "$name" "$value"
  echo "Exported env $name"
done <<< "${CW_RESPONSE_MAP:-}"

# ---------- wait for async operation ----------
# /operation/{id} responses include the whole server with plaintext credentials
# for every app on it, so only print selected fields from them.
OP=""
[ "$IS_JSON" = true ] && OP="$(echo "$RESP" | jq -r 'try (.operation_id // .data.operation_id // empty | tostring) catch empty')"
[[ "$OP" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || OP=""
emit "$GITHUB_OUTPUT" operation-id "$OP"

if [ -n "$OP" ] && [ "$WAIT" = "true" ]; then
  echo "Waiting for operation $OP (timeout ${OP_TIMEOUT}s)"
  start=$(date +%s)
  while :; do
    if ! r="$(LVL=warning NOBODY=1 call GET "/operation/$OP")"; then
      echo "::warning::Could not poll operation $OP; continuing without waiting"
      break
    fi
    done_flag="$(echo "$r" | jq -r 'try ((.operation // .data.operation).is_completed // empty) catch empty')"
    if [ "$done_flag" = "1" ] || [ "$done_flag" = "true" ]; then
      echo "Operation $OP completed"
      break
    fi
    if [ "$done_flag" = "-1" ]; then
      echo "::error::Operation $OP failed: $(echo "$r" | jq -c '(.operation // .data.operation) | {id, type, status, message}' | oneline)"
      exit 1
    fi
    if [ $(( $(date +%s) - start )) -ge "$OP_TIMEOUT" ]; then
      echo "::warning::Operation $OP not completed after ${OP_TIMEOUT}s"
      break
    fi
    sleep 5
  done
fi
