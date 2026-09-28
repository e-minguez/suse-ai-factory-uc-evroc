#!/usr/bin/env bash
#
# Import ONE existing downstream RKE2 cluster into a management Rancher.
#
# WHY THE RANCHER HTTP API RATHER THAN A MANAGEMENT KUBECONFIG:
# The whole point of the management/downstream split (README.md section 6) is
# that an operator normally only has direct access to the cluster they are
# working on, not a kubeconfig for whichever cluster happens to be running
# Rancher. Rancher's own API is enough to log in, check settings, create the
# provisioning object and pull a registration manifest -- nothing here needs
# cluster-admin on the management cluster itself.
#
# WHY TFSTATE IS READ-ONLY, VIA jq, NEVER VIA terraform:
# terraform.tfstate holds live infrastructure state for a cluster that may be
# mid-apply in another terminal, or may belong to someone else's checkout of
# this directory entirely (see section 6.1). Any `terraform` subcommand -- even
# a read-only `output` -- takes a state lock and, on an old CLI or a stale
# .terraform directory, can trigger a provider/version check against files
# this script has no business touching. `jq` against the JSON on disk needs
# none of that and cannot write to it. This script therefore never invokes
# `terraform` at all -- see the tfstate_output() helper below, the only place
# a tfstate file is read.
#
# WHY THE DOWNSTREAM SIDE STILL NEEDS A KUBECONFIG:
# Unlike the management side, there is no way to apply the registration
# manifest -- a Kubernetes manifest of cattle-system objects -- without
# talking to the downstream cluster's own API server. Rancher's API cannot
# reach into a cluster it does not know about yet; that is exactly the gap
# this script closes.
#
# USAGE:
#   ./clusters-to-rancher.sh \
#     --management-cluster-tfstate ../mgmt/terraform.tfstate \
#     --downstream-cluster-tfstate ../gpu-a/terraform.tfstate \
#     --downstream-cluster-kubeconfig ~/gpu-a.yaml
#
# See README.md section 6.3 for the full flag table.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./clusters-to-rancher.sh --downstream-cluster-kubeconfig PATH [options]

Management cluster (Rancher side):
  --management-cluster-tfstate PATH
      Path to the management cluster's terraform.tfstate. Source of
      rancher_url and rancher_bootstrap_password unless overridden below.
  --management-cluster-url URL
      Overrides the management cluster's Rancher URL.
  --management-cluster-user USER
      Rancher login user on the management cluster. Default: admin.
  --management-cluster-password PASSWORD
      Rancher login password on the management cluster. Default: the
      MGMT_RANCHER_PASSWORD environment variable, else the management
      tfstate's rancher_bootstrap_password output. That value is the
      BOOTSTRAP password and goes stale the moment anyone changes it in the
      Rancher UI -- prefer this flag or MGMT_RANCHER_PASSWORD on any cluster
      past first boot.

Downstream cluster (the one being imported):
  --downstream-cluster-tfstate PATH
      Path to the downstream cluster's terraform.tfstate. Source of
      api_host/api_vip (used to rewrite the kubeconfig's server:) and the
      default --cluster-name.
  --downstream-cluster-kubeconfig PATH
      REQUIRED. Path to the downstream cluster's own kubeconfig (e.g.
      /etc/rancher/rke2/rke2.yaml fetched per README.md section 6.2).
  --downstream-cluster-api URL
      Overrides the downstream cluster's API address (and the kubeconfig's
      server: field). Default: https://<api_host>:6443 from tfstate, else
      https://<api_vip>:6443.
  --cluster-name NAME
      Display name the cluster gets in Rancher. Default: the downstream
      tfstate's cluster_name output, else the basename of the directory the
      downstream tfstate lives in. Normalised to a DNS-1123 label (lowercase,
      invalid characters become '-', leading/trailing '-' trimmed, truncated
      to 63 characters); the script dies if nothing legal is left.

Other:
  --insecure    Skip TLS verification against the management Rancher's API.
  --wait        Block until the downstream cluster reports ready in Rancher.
  --timeout SECS
      How long --wait blocks before giving up. Default: 600.
  --yes         Skip the confirmation prompt (also required if stdin is not
                a terminal).
  --help        Show this message and exit.

Any explicit flag overrides the matching tfstate-derived value. Precedence
for the password specifically: flag > MGMT_RANCHER_PASSWORD > tfstate.

This script only READS tfstate files (with jq) to fill in defaults. It never
runs terraform and never writes to either cluster's Terraform state.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Flag parsing. Unrecognised --flags are a hard error rather than being
# forwarded anywhere -- there is nothing downstream of this script that a
# stray flag could sensibly mean, unlike deploy.sh's terraform passthrough.
# ---------------------------------------------------------------------------
MGMT_TFSTATE=""
MGMT_URL_FLAG=""
MGMT_USER="admin"
MGMT_PASSWORD_FLAG=""
DOWNSTREAM_TFSTATE=""
DOWNSTREAM_KUBECONFIG=""
DOWNSTREAM_API_FLAG=""
CLUSTER_NAME_FLAG=""
INSECURE=false
WAIT=false
TIMEOUT=600
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --management-cluster-tfstate)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      MGMT_TFSTATE="$2"; shift 2 ;;
    --management-cluster-url)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      MGMT_URL_FLAG="$2"; shift 2 ;;
    --management-cluster-user)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      MGMT_USER="$2"; shift 2 ;;
    --management-cluster-password)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      MGMT_PASSWORD_FLAG="$2"; shift 2 ;;
    --downstream-cluster-tfstate)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      DOWNSTREAM_TFSTATE="$2"; shift 2 ;;
    --downstream-cluster-kubeconfig)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      DOWNSTREAM_KUBECONFIG="$2"; shift 2 ;;
    --downstream-cluster-api)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      DOWNSTREAM_API_FLAG="$2"; shift 2 ;;
    --cluster-name)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      CLUSTER_NAME_FLAG="$2"; shift 2 ;;
    --insecure) INSECURE=true; shift ;;
    --wait) WAIT=true; shift ;;
    --timeout)
      [[ $# -ge 2 ]] || die "$1 requires an argument."
      TIMEOUT="$2"; shift 2 ;;
    --yes) YES=true; shift ;;
    --help | -h)
      usage
      exit 0
      ;;
    --*)
      echo "ERROR: unknown option '$1'." >&2
      echo >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "ERROR: unexpected argument '$1'." >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a positive integer number of seconds, got '$TIMEOUT'." ;;
esac
[[ -n "$DOWNSTREAM_KUBECONFIG" ]] || die "--downstream-cluster-kubeconfig is required."
[[ -f "$DOWNSTREAM_KUBECONFIG" ]] || die "Downstream kubeconfig not found: $DOWNSTREAM_KUBECONFIG"
[[ -z "$MGMT_TFSTATE" || -f "$MGMT_TFSTATE" ]] || die "Management tfstate not found: $MGMT_TFSTATE"
[[ -z "$DOWNSTREAM_TFSTATE" || -f "$DOWNSTREAM_TFSTATE" ]] || die "Downstream tfstate not found: $DOWNSTREAM_TFSTATE"

# ---------------------------------------------------------------------------
# Prechecks.
# ---------------------------------------------------------------------------
for bin in curl jq kubectl; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but was not found in PATH."
done

# ---------------------------------------------------------------------------
# Cleanup. Declared before anything that could die(), so the trap always has
# defined (if empty/unset-value) variables to look at under `set -u` -- an
# empty array expands safely with the ${arr[@]+"${arr[@]}"} idiom below (see
# deploy.sh's own TF_ARGS for the same pattern); bash 3.2 treats a bare
# "${arr[@]}" on a truly empty array as an unbound-variable error.
# ---------------------------------------------------------------------------
TMP_FILES=()
TOKEN=""
TOKEN_HEADER_FILE=""
MGMT_URL=""
CURL_OPTS=(--max-time 15)

cleanup() {
  local rc=$?
  # Best-effort: a failed logout must never mask the real exit code, and must
  # never re-trigger `set -e` while we are already unwinding on EXIT.
  if [[ -n "$TOKEN_HEADER_FILE" && -f "$TOKEN_HEADER_FILE" && -n "$MGMT_URL" ]]; then
    curl -sS -X POST --max-time 10 "${CURL_OPTS[@]}" \
      -H "@${TOKEN_HEADER_FILE}" \
      "${MGMT_URL%/}/v3/tokens?action=logout" >/dev/null 2>&1 || true
  fi
  local f
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
  exit "$rc"
}
trap cleanup EXIT

[[ "$INSECURE" == true ]] && CURL_OPTS+=(-k)

# ---------------------------------------------------------------------------
# tfstate reader. HARD RULE: this is the only way tfstate is ever touched --
# no `terraform output`, no `terraform` invocation of any kind. `// empty`
# collapses both a JSON null (an output that exists but has no value, e.g.
# rancher_url on a cluster without the rancher component) and a wholly
# missing key (an output that was never defined) to the same empty string,
# which is what "resolve from flag/env, else this, else die" below expects.
# ---------------------------------------------------------------------------
tfstate_output() {
  local file="$1" name="$2"
  jq -r --arg name "$name" '.outputs[$name].value // empty' "$file"
}

# ---------------------------------------------------------------------------
# DNS-1123 label normalisation for --cluster-name. Pure tr/sed, no bash
# ${var,,} (not in bash 3.2) and no external tools beyond what deploy.sh
# already assumes (sed, tr are POSIX).
# ---------------------------------------------------------------------------
normalize_cluster_name() {
  local out
  out=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')
  out="${out:0:63}"
  # Truncating to 63 chars can leave a trailing '-' that survived the first
  # trim because it used to have non-dash characters after it.
  out=$(printf '%s' "$out" | sed -E 's/-+$//')
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Resolve management cluster settings.
# Precedence: explicit flag > env (password only) > tfstate.
# ---------------------------------------------------------------------------
MGMT_URL="$MGMT_URL_FLAG"
if [[ -z "$MGMT_URL" ]]; then
  [[ -n "$MGMT_TFSTATE" ]] || die "No --management-cluster-url given and no --management-cluster-tfstate to read rancher_url from. Pass one of the two."
  MGMT_URL=$(tfstate_output "$MGMT_TFSTATE" rancher_url)
  [[ -n "$MGMT_URL" ]] || die "Management tfstate '$MGMT_TFSTATE' output 'rancher_url' is null or missing -- this means 'rancher' is not in that cluster's components. Pass --management-cluster-url explicitly."
fi

MGMT_PASSWORD="$MGMT_PASSWORD_FLAG"
if [[ -z "$MGMT_PASSWORD" ]]; then
  MGMT_PASSWORD="${MGMT_RANCHER_PASSWORD:-}"
fi
if [[ -z "$MGMT_PASSWORD" ]]; then
  [[ -n "$MGMT_TFSTATE" ]] || die "No password given (--management-cluster-password or MGMT_RANCHER_PASSWORD) and no --management-cluster-tfstate to read rancher_bootstrap_password from."
  MGMT_PASSWORD=$(tfstate_output "$MGMT_TFSTATE" rancher_bootstrap_password)
  [[ -n "$MGMT_PASSWORD" ]] || die "Management tfstate '$MGMT_TFSTATE' output 'rancher_bootstrap_password' is null or missing -- this means 'rancher' is not in that cluster's components. Pass --management-cluster-password or set MGMT_RANCHER_PASSWORD."
fi

# ---------------------------------------------------------------------------
# Resolve downstream cluster settings.
# ---------------------------------------------------------------------------
DOWNSTREAM_API=""
if [[ -n "$DOWNSTREAM_API_FLAG" ]]; then
  DOWNSTREAM_API="$DOWNSTREAM_API_FLAG"
elif [[ -n "$DOWNSTREAM_TFSTATE" ]]; then
  api_host=$(tfstate_output "$DOWNSTREAM_TFSTATE" api_host)
  if [[ -n "$api_host" ]]; then
    DOWNSTREAM_API="https://${api_host}:6443"
  else
    api_vip=$(tfstate_output "$DOWNSTREAM_TFSTATE" api_vip)
    [[ -n "$api_vip" ]] && DOWNSTREAM_API="https://${api_vip}:6443"
  fi
fi

if [[ -n "$CLUSTER_NAME_FLAG" ]]; then
  CLUSTER_NAME_RAW="$CLUSTER_NAME_FLAG"
elif [[ -n "$DOWNSTREAM_TFSTATE" ]]; then
  CLUSTER_NAME_RAW=$(tfstate_output "$DOWNSTREAM_TFSTATE" cluster_name)
  if [[ -z "$CLUSTER_NAME_RAW" ]]; then
    # dirname/basename rather than `dirname ... | xargs basename`: the tfstate
    # path may be relative, and cd+pwd resolves it without caring either way.
    CLUSTER_NAME_RAW=$(cd "$(dirname "$DOWNSTREAM_TFSTATE")" && basename "$(pwd)")
  fi
else
  die "No --cluster-name given and no --downstream-cluster-tfstate to derive a default from. Pass one of the two."
fi
CLUSTER_NAME=$(normalize_cluster_name "$CLUSTER_NAME_RAW")
[[ -n "$CLUSTER_NAME" ]] || die "Resolved cluster name is empty after DNS-1123 normalisation (raw value: '${CLUSTER_NAME_RAW}')."

# ---------------------------------------------------------------------------
# Downstream kubeconfig: work on a private copy, never the operator's own
# file. mktemp, not a path under either cluster directory -- this repo's HARD
# RULE is that nothing here writes into a cluster's own directory.
# ---------------------------------------------------------------------------
TMP_KUBECONFIG=$(mktemp "${TMPDIR:-/tmp}/clusters-to-rancher-kubeconfig.XXXXXX")
TMP_FILES+=("$TMP_KUBECONFIG")
cp "$DOWNSTREAM_KUBECONFIG" "$TMP_KUBECONFIG"
chmod 600 "$TMP_KUBECONFIG"

# --minify: reduce the view to current-context's own cluster/user/context
# entries only. Without it, `.clusters[0]` is whichever cluster happens to
# sort first in the file, which is only ever "the right one" by luck on a
# kubeconfig with more than one cluster entry (rke2.yaml normally has just
# one, but nothing guarantees the file handed to this script does).
CURRENT_SERVER=$(kubectl --kubeconfig "$TMP_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
case "$CURRENT_SERVER" in
  https://127.0.0.1:*|http://127.0.0.1:*|https://localhost:*|http://localhost:*) IS_LOOPBACK=true ;;
  *) IS_LOOPBACK=false ;;
esac

if [[ -n "$DOWNSTREAM_API" ]]; then
  # rke2.yaml's single cluster entry is named "default"; read the real
  # current-context cluster name rather than assuming it, since a hand-edited
  # kubeconfig might differ.
  KCTX_NAME=$(kubectl --kubeconfig "$TMP_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].name}')
  kubectl --kubeconfig "$TMP_KUBECONFIG" config set-cluster "$KCTX_NAME" --server="$DOWNSTREAM_API" >/dev/null
elif [[ "$IS_LOOPBACK" == true ]]; then
  die "Downstream kubeconfig's server is ${CURRENT_SERVER} (only reachable on the node itself) and no API address was resolved. Pass --downstream-cluster-api, or --downstream-cluster-tfstate so api_host/api_vip can be used to rewrite it."
else
  # The kubeconfig already points somewhere off-node and nothing overrides
  # it -- use it as given rather than forcing a rewrite that was not asked for.
  DOWNSTREAM_API="$CURRENT_SERVER"
fi

echo "==> Verifying the downstream cluster answers at ${DOWNSTREAM_API}"
kubectl --kubeconfig "$TMP_KUBECONFIG" --request-timeout=15s get --raw /readyz >/dev/null \
  || die "Downstream cluster API at ${DOWNSTREAM_API} did not answer /readyz within 15s. Check --downstream-cluster-api / the kubeconfig, and that this host can reach it (rke2's certificate SANs include api_host, which is why it is preferred over api_vip)."

# ---------------------------------------------------------------------------
# Rancher /ping: bounded retries, not an infinite wait -- a Rancher that is
# simply unreachable should fail this script promptly, not hang it forever.
# curl exit 60 is a TLS verification failure specifically, which almost
# always means the self-signed certificate Rancher serves by default; that
# gets its own message rather than the generic "unreachable" one.
#
# Success is HTTP 200 with the literal body "pong" -- Rancher's real /ping
# handler -- not just "curl didn't fail". A bare TCP/TLS success is not
# enough: an ingress whose default backend answers 404/503 (Rancher not
# actually up behind it yet, or the wrong host routed) looks reachable to
# curl but is not Rancher, and would otherwise pass this check only to fail
# confusingly at login a moment later. 20 attempts * 3s gives a freshly
# started Rancher pod real time to come up behind the ingress.
# ---------------------------------------------------------------------------
echo "==> Checking Rancher at ${MGMT_URL}"
ping_attempt=1
ping_max=20
PING_STATUS=""
PING_TEXT=""
while :; do
  # `|| rc=$?` rather than `if curl ...; then break; fi; rc=$?`: when the
  # `if`'s condition is false and there is no `else`, POSIX defines the
  # compound's own exit status as 0 regardless of what the condition
  # returned, so a bare `rc=$?` placed after `fi` silently reads back 0 --
  # not curl's real exit code -- on every failure. This form captures it
  # correctly, and `|| rc=$?` (rather than a bare failing command) keeps
  # `set -e` from treating the failure as fatal here.
  rc=0
  ping_out=$(curl -sS "${CURL_OPTS[@]}" -w '\n%{http_code}' "${MGMT_URL%/}/ping") || rc=$?
  if [[ $rc -eq 60 ]]; then
    die "TLS certificate verification failed connecting to ${MGMT_URL} (curl exit 60). Rancher serves a self-signed certificate by default -- pass --insecure to skip verification, or trust its CA first."
  fi
  if [[ $rc -eq 0 ]]; then
    PING_STATUS="${ping_out##*$'\n'}"
    PING_TEXT="${ping_out%$'\n'*}"
    if [[ "$PING_STATUS" == "200" && "$PING_TEXT" == "pong" ]]; then
      break
    fi
  fi
  if [[ $ping_attempt -ge $ping_max ]]; then
    die "Rancher at ${MGMT_URL} did not answer /ping with HTTP 200 \"pong\" after ${ping_max} attempts (last: curl exit ${rc}, HTTP ${PING_STATUS:-n/a}, body '${PING_TEXT:-}'). Check --management-cluster-url and network connectivity -- a wrong host or an ingress with no Rancher behind it yet both look reachable without being it."
  fi
  echo "    not reachable yet (attempt ${ping_attempt}/${ping_max}), retrying..." >&2
  ping_attempt=$((ping_attempt + 1))
  sleep 3
done

# ---------------------------------------------------------------------------
# HTTP helpers.
#
# rancher_raw NEVER dies, on a non-2xx or on a network-level failure --
# poll loops (waiting for a cluster id, a registration token, readiness) call
# it directly and must be able to treat "Rancher hiccuped for one request" as
# "try again", not as fatal. A network error is reported to the caller as
# HTTP_STATUS=000 (a status curl itself can never produce), so callers can
# tell it apart from a real HTTP response with a single numeric comparison.
#
# rancher_request wraps it for one-shot calls that SHOULD die immediately on
# any failure (login, settings PUT, cluster/token create): it dies with
# Rancher's own error message on a non-2xx, or a network-error message on 000.
#
# Request bodies go in via --data @- (stdin) and the bearer token via
# `-H @file` (a temp file holding the Authorization header line, curl >=
# 7.55) rather than `-H "Authorization: Bearer $TOKEN"` on argv -- neither
# the password nor the token is ever a literal argv value, so neither shows
# up in `ps` output.
# ---------------------------------------------------------------------------
rancher_raw() {
  local method="$1" path="$2" data="${3:-}"
  local -a curl_args
  local out
  curl_args=(-sS -X "$method" -w '\n%{http_code}')
  curl_args+=("${CURL_OPTS[@]}")
  if [[ -n "$TOKEN_HEADER_FILE" ]]; then
    curl_args+=(-H "@${TOKEN_HEADER_FILE}")
  fi
  if [[ -n "$data" ]]; then
    curl_args+=(-H 'Content-Type: application/json' --data @-)
    if ! out=$(printf '%s' "$data" | curl "${curl_args[@]}" "${MGMT_URL%/}${path}"); then
      HTTP_STATUS="000"
      HTTP_BODY="(network error contacting Rancher for ${method} ${path})"
      return 0
    fi
  else
    if ! out=$(curl "${curl_args[@]}" "${MGMT_URL%/}${path}"); then
      HTTP_STATUS="000"
      HTTP_BODY="(network error contacting Rancher for ${method} ${path})"
      return 0
    fi
  fi
  HTTP_STATUS="${out##*$'\n'}"
  HTTP_BODY="${out%$'\n'*}"
}

rancher_request() {
  local method="$1" path="$2"
  rancher_raw "$@"
  if [[ "$HTTP_STATUS" == "000" ]]; then
    die "Network error contacting Rancher for ${method} ${path}."
  fi
  if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
    local msg
    msg=$(printf '%s' "$HTTP_BODY" | jq -r '.message // .Message // empty' 2>/dev/null || true)
    die "Rancher API ${method} ${path} failed (HTTP ${HTTP_STATUS})${msg:+: ${msg}}"
  fi
  printf '%s' "$HTTP_BODY"
}

# 404-tolerant: a setting that does not exist on this Rancher version (e.g.
# agent-tls-mode on Rancher <2.9) reads back as empty, exactly like a setting
# that exists but has an empty value. Callers that must tell "absent" from
# "present but empty" apart (see the agent-tls-mode check below) use
# rancher_raw directly instead of this helper.
get_setting() {
  rancher_raw GET "/v3/settings/$1"
  if [[ "$HTTP_STATUS" == "404" ]]; then
    printf ''
    return 0
  fi
  if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
    local msg
    msg=$(printf '%s' "$HTTP_BODY" | jq -r '.message // .Message // empty' 2>/dev/null || true)
    die "Rancher API GET /v3/settings/$1 failed (HTTP ${HTTP_STATUS})${msg:+: ${msg}}"
  fi
  printf '%s' "$HTTP_BODY" | jq -r '.value // empty'
}

# ---------------------------------------------------------------------------
# Login. Rancher 2.14.3's public login endpoint moved from the /v3-public
# path to /v1-public/login; try the new one first and fall back to the old
# one, but only when the new one's response says "this endpoint/shape is not
# what I expected" (404/400/405/422) -- a Rancher that has not moved yet, or
# a client.LocalProviderType payload it does not recognise in that shape.
# 401/403 mean the credentials themselves were rejected, which the fallback
# would only repeat against the same local provider, so those die immediately
# instead.
#
# `type: "localProvider"` (not "local"): verified against rancher/rancher
# v2.14.3's providerInputForType, which switches on client.LocalProviderType
# == "localProvider" for this endpoint -- "local" is the older /v3-public
# provider name and is only correct on the fallback path below.
# mustChangePassword does not block the API, so it is never consulted or
# reset here -- doing so would be a destructive side effect this script has
# no business taking on a management cluster's admin account.
# ---------------------------------------------------------------------------
echo "==> Logging in to Rancher as ${MGMT_USER}"
login_payload=$(jq -n --arg u "$MGMT_USER" --arg p "$MGMT_PASSWORD" \
  '{type: "localProvider", username: $u, password: $p, responseType: "json"}')
rancher_raw POST "/v1-public/login" "$login_payload"
case "$HTTP_STATUS" in
  401 | 403)
    msg=$(printf '%s' "$HTTP_BODY" | jq -r '.message // .Message // empty' 2>/dev/null || true)
    die "Rancher login failed: bad credentials for ${MGMT_USER} (HTTP ${HTTP_STATUS})${msg:+: ${msg}}"
    ;;
  400 | 404 | 405 | 422)
    login_payload=$(jq -n --arg u "$MGMT_USER" --arg p "$MGMT_PASSWORD" \
      '{username: $u, password: $p, responseType: "json"}')
    rancher_raw POST "/v3-public/localProviders/local?action=login" "$login_payload"
    ;;
esac
unset login_payload
if [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]]; then
  msg=$(printf '%s' "$HTTP_BODY" | jq -r '.message // .Message // empty' 2>/dev/null || true)
  die "Rancher login failed: bad credentials for ${MGMT_USER} (HTTP ${HTTP_STATUS})${msg:+: ${msg}}"
fi
if [[ "$HTTP_STATUS" == "000" ]]; then
  die "Network error logging in to Rancher at ${MGMT_URL}."
fi
if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
  msg=$(printf '%s' "$HTTP_BODY" | jq -r '.message // .Message // empty' 2>/dev/null || true)
  die "Rancher login failed (HTTP ${HTTP_STATUS})${msg:+: ${msg}}"
fi
TOKEN=$(printf '%s' "$HTTP_BODY" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || die "Rancher login returned no token."
MGMT_PASSWORD=""  # no longer needed; do not keep it around longer than necessary

# Bearer token to a private temp file rather than argv from here on (see the
# HTTP-helpers comment above): created by mktemp before anything is written
# to it, permissioned before the token touches it, and removed in the EXIT
# trap alongside the kubeconfig copy.
TOKEN_HEADER_FILE=$(mktemp "${TMPDIR:-/tmp}/clusters-to-rancher-token.XXXXXX")
TMP_FILES+=("$TOKEN_HEADER_FILE")
chmod 600 "$TOKEN_HEADER_FILE"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TOKEN_HEADER_FILE"

# ---------------------------------------------------------------------------
# Settings checks.
# ---------------------------------------------------------------------------
NORM_MGMT_URL="${MGMT_URL%/}"

SERVER_URL=$(get_setting server-url)
PENDING_SET_SERVER_URL=false
if [[ -z "$SERVER_URL" ]]; then
  # Deferred to a pending action shown in the summary/confirmation below,
  # rather than a PUT here -- nothing is written to Rancher before that
  # prompt is answered.
  PENDING_SET_SERVER_URL=true
elif [[ "${SERVER_URL%/}" != "$NORM_MGMT_URL" ]]; then
  echo "WARNING: Rancher's server-url setting (${SERVER_URL%/}) differs from the URL used here (${NORM_MGMT_URL}). The downstream agent dials server-url, not this script's --management-cluster-url." >&2
fi

# agent-tls-mode defaults to "strict" on a fresh install; cacerts is
# auto-populated by Rancher only when ingress.tls.source=rancher (this repo's
# default -- see modules/ai-factory-ha). strict + empty cacerts means the
# agent's TLS handshake against Rancher will never succeed, so refuse rather
# than register a cluster that can only ever sit "pending".
AGENT_TLS_MODE=$(get_setting agent-tls-mode)
CACERTS=$(get_setting cacerts)
if [[ "$AGENT_TLS_MODE" == "strict" && -z "$CACERTS" ]]; then
  die "Rancher's agent-tls-mode is 'strict' and cacerts is empty: the downstream cattle-cluster-agent would fail CA verification against Rancher's certificate and never connect. Fix one of: give Rancher a certificate from a publicly-trusted CA and set agent-tls-mode=system-store, or populate the cacerts setting with Rancher's CA certificate, then re-run."
fi

# ---------------------------------------------------------------------------
# Already-linked checks, BEFORE any write.
#
# `get --raw` + jq rather than `kubectl get deployment -o jsonpath=...`: the
# jsonpath form needs client-go's RESTMapper, which does a round of discovery
# (/api, /apis, and friends) before it can even resolve "deployment" to
# apps/v1 -- several extra requests, all fallible in slightly different ways,
# for what is otherwise a single well-known REST path. --raw skips discovery
# entirely and returns exactly the object at that path, or a clean 404 --
# jq then does the field extraction jsonpath would have done.
# ---------------------------------------------------------------------------
# A downstream agent dials CATTLE_SERVER, which is set from whichever
# Rancher server-url it registered against -- not necessarily the URL this
# invocation was given. Match against EITHER this run's --management-cluster-url
# (NORM_MGMT_URL) OR Rancher's own server-url setting (SERVER_URL, fetched
# above, before this check): the two can legitimately differ (a load-balancer
# hostname in server-url vs. a direct node address passed here), and either
# one matching means it is genuinely this Rancher.
AGENT_JSON=$(kubectl --kubeconfig "$TMP_KUBECONFIG" --request-timeout=15s \
  get --raw /apis/apps/v1/namespaces/cattle-system/deployments/cattle-cluster-agent 2>/dev/null || true)
if [[ -n "$AGENT_JSON" ]]; then
  CATTLE_SERVER=$(printf '%s' "$AGENT_JSON" \
    | jq -r '[.spec.template.spec.containers[]?.env[]? | select(.name == "CATTLE_SERVER") | .value][0] // empty')
  if [[ -n "$CATTLE_SERVER" ]]; then
    NORM_CATTLE_SERVER="${CATTLE_SERVER%/}"
    NORM_SERVER_URL_SETTING="${SERVER_URL%/}"
    if [[ "$NORM_CATTLE_SERVER" == "$NORM_MGMT_URL" ]] \
      || [[ -n "$NORM_SERVER_URL_SETTING" && "$NORM_CATTLE_SERVER" == "$NORM_SERVER_URL_SETTING" ]]; then
      echo "Downstream cluster is already imported into this Rancher (${NORM_MGMT_URL})."
      exit 0
    else
      die "Downstream cluster's cattle-cluster-agent is already linked to a different Rancher: ${CATTLE_SERVER}"
    fi
  fi
fi

rancher_raw GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}"
RESUME=false
CLUSTER_CREATED=""
case "$HTTP_STATUS" in
  200)
    READY=$(printf '%s' "$HTTP_BODY" | jq -r '.status.ready // false')
    if [[ "$READY" == "true" ]]; then
      die "A cluster named '${CLUSTER_NAME}' already exists in Rancher and is connected/ready. Pass --cluster-name to register this downstream cluster under a different name."
    fi
    # Only adopt a not-ready cluster that this script (or something like it)
    # could plausibly have created and that never finished connecting:
    # spec.rkeConfig is Rancher's own RKE2-provisioning config, present on
    # any cluster Rancher itself provisioned the nodes for -- an imported
    # cluster (what this script creates) never has one. A Connected=True
    # condition means an agent has dialled in at some point, even if the
    # cluster is not currently ready -- adopting that would silently steal a
    # cluster identity out from under whatever is really driving it.
    HAS_RKECONFIG=$(printf '%s' "$HTTP_BODY" | jq -r 'if (.spec.rkeConfig // null) == null then "false" else "true" end')
    WAS_CONNECTED=$(printf '%s' "$HTTP_BODY" | jq -r '[.status.conditions[]? | select(.type == "Connected" and .status == "True")] | length > 0')
    if [[ "$HAS_RKECONFIG" == "true" || "$WAS_CONNECTED" == "true" ]]; then
      die "A cluster named '${CLUSTER_NAME}' already exists in Rancher but is not something this script can safely adopt (it carries an rkeConfig and/or has connected before). Pass --cluster-name to register this downstream cluster under a different name."
    fi
    RESUME=true
    CLUSTER_CREATED=$(printf '%s' "$HTTP_BODY" | jq -r '.metadata.creationTimestamp // empty')
    ;;
  404) RESUME=false ;;
  *) die "Rancher API GET provisioning cluster '${CLUSTER_NAME}' failed (HTTP ${HTTP_STATUS})." ;;
esac

# ---------------------------------------------------------------------------
# Summary + confirmation. Nothing above this point wrote anything to Rancher
# or the downstream cluster.
# ---------------------------------------------------------------------------
echo
echo "== Summary =="
echo "Management Rancher:  ${MGMT_URL} (user: ${MGMT_USER})"
echo "Downstream API:      ${DOWNSTREAM_API}"
echo "Cluster name:        ${CLUSTER_NAME}"
if [[ "$PENDING_SET_SERVER_URL" == true ]]; then
  echo "Pending action:      set Rancher's server-url setting to ${NORM_MGMT_URL} (currently unset; required for an agent to register)"
fi
if [[ "$RESUME" == true ]]; then
  echo "Action:              adopt existing Rancher cluster '${CLUSTER_NAME}' (created ${CLUSTER_CREATED:-unknown}, never connected) and register THIS downstream as it"
else
  echo "Action:              create and register a new cluster '${CLUSTER_NAME}'"
fi
echo

if [[ "$YES" != true ]]; then
  if [[ ! -t 0 ]]; then
    die "Refusing to prompt for confirmation: stdin is not a terminal and --yes was not given."
  fi
  REPLY=""
  read -r -p "Import '${CLUSTER_NAME}' into Rancher at ${MGMT_URL}? [y/N] " REPLY
  case "$REPLY" in
    [yY] | [yY][eE][sS]) ;;
    *)
      echo "Aborted; nothing was changed."
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Execute.
# ---------------------------------------------------------------------------
if [[ "$PENDING_SET_SERVER_URL" == true ]]; then
  echo "==> Setting Rancher's server-url to ${NORM_MGMT_URL}"
  payload=$(jq -n --arg name "server-url" --arg value "$NORM_MGMT_URL" '{name: $name, value: $value}')
  rancher_request PUT "/v3/settings/server-url" "$payload" >/dev/null
  unset payload
fi

if [[ "$RESUME" == true ]]; then
  echo "==> Adopting existing cluster '${CLUSTER_NAME}' (created ${CLUSTER_CREATED:-unknown}, never connected)"
else
  echo "==> Creating provisioning cluster '${CLUSTER_NAME}'"
  payload=$(jq -n --arg name "$CLUSTER_NAME" \
    '{type: "provisioning.cattle.io.cluster", metadata: {name: $name, namespace: "fleet-default"}, spec: {}}')
  rancher_request POST "/v1/provisioning.cattle.io.clusters" "$payload" >/dev/null
  unset payload
fi

# ---------------------------------------------------------------------------
# body_excerpt: trims HTTP_BODY to something short enough for a one-line die()
# message -- Rancher error bodies are occasionally an HTML error page from an
# intermediate proxy, not JSON, so this does not assume either shape.
# ---------------------------------------------------------------------------
body_excerpt() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-200
}

echo "==> Waiting for Rancher to assign a cluster id to '${CLUSTER_NAME}'"
# rancher_raw, not rancher_request: Rancher can 5xx or the connection can drop
# for one request while the provisioning cluster is still being reconciled --
# that is transient, not fatal, so every non-2xx here is just another failed
# attempt to retry, and only running out of attempts is a real failure.
CLUSTER_ID=""
attempt=0
clusterid_max=40
while [[ $attempt -lt $clusterid_max ]]; do
  rancher_raw GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}"
  if [[ "$HTTP_STATUS" == "200" ]]; then
    CLUSTER_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.status.clusterName // empty')
    [[ -n "$CLUSTER_ID" ]] && break
  fi
  attempt=$((attempt + 1))
  sleep 3
done
[[ -n "$CLUSTER_ID" ]] || die "Timed out waiting for Rancher to assign a cluster id (status.clusterName) to '${CLUSTER_NAME}' after ${clusterid_max} attempts (last HTTP ${HTTP_STATUS}: $(body_excerpt "$HTTP_BODY")). The provisioning cluster '${CLUSTER_NAME}' was already created in Rancher -- re-running this script will resume from it rather than creating a duplicate."
echo "    cluster id: ${CLUSTER_ID}"

# fetch_manifest_url uses rancher_raw directly (not rancher_request) for the
# same reason as above: a transient failure listing tokens must not abort the
# whole script, only this one lookup, so callers below retry it themselves
# rather than dying the first time it comes back empty or non-2xx. It sets
# MANIFEST_URL instead of printing it: called as $(...) it would run in a
# subshell, and the HTTP_STATUS/HTTP_BODY the timeout messages below quote
# would be left stale from an earlier request.
fetch_manifest_url() {
  MANIFEST_URL=""
  rancher_raw GET "/v3/clusterregistrationtokens?clusterId=${CLUSTER_ID}"
  [[ "$HTTP_STATUS" == "200" ]] || return 0
  MANIFEST_URL=$(printf '%s' "$HTTP_BODY" | jq -r '[.data[]? | select(.manifestUrl != null and .manifestUrl != "")][0].manifestUrl // empty')
}

echo "==> Fetching a cluster registration token"
fetch_manifest_url
if [[ -z "$MANIFEST_URL" ]]; then
  echo "    none exists yet; creating one"
  payload=$(jq -n --arg id "$CLUSTER_ID" '{type: "clusterRegistrationToken", clusterId: $id}')
  attempt=0
  create_token_max=10
  CREATED_TOKEN=false
  while [[ $attempt -lt $create_token_max ]]; do
    rancher_raw POST "/v3/clusterregistrationtokens" "$payload"
    if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
      CREATED_TOKEN=true
      break
    fi
    attempt=$((attempt + 1))
    sleep 3
  done
  unset payload
  [[ "$CREATED_TOKEN" == true ]] || die "Timed out creating a clusterregistrationtoken for cluster id ${CLUSTER_ID} after ${create_token_max} attempts (last HTTP ${HTTP_STATUS}: $(body_excerpt "$HTTP_BODY")). The provisioning cluster '${CLUSTER_NAME}' (id ${CLUSTER_ID}) already exists in Rancher -- re-running this script will resume from it."
fi
attempt=0
manifest_max=40
while [[ -z "$MANIFEST_URL" && $attempt -lt $manifest_max ]]; do
  sleep 3
  fetch_manifest_url
  attempt=$((attempt + 1))
done
[[ -n "$MANIFEST_URL" ]] || die "Timed out waiting for a clusterregistrationtokens manifestUrl for cluster id ${CLUSTER_ID} after ${manifest_max} attempts (last HTTP ${HTTP_STATUS}: $(body_excerpt "$HTTP_BODY")). The provisioning cluster '${CLUSTER_NAME}' (id ${CLUSTER_ID}) already exists in Rancher -- re-running this script will resume from it."

echo "==> Applying the registration manifest to the downstream cluster"
manifest_curl_args=(-sS -fL --max-time 30)
[[ "$INSECURE" == true ]] && manifest_curl_args+=(-k)
curl "${manifest_curl_args[@]}" "$MANIFEST_URL" | kubectl --kubeconfig "$TMP_KUBECONFIG" apply -f - \
  || die "Applying the registration manifest to the downstream cluster failed."

if [[ "$WAIT" == true ]]; then
  echo "==> Waiting up to ${TIMEOUT}s for cluster '${CLUSTER_NAME}' to report ready"
  # rancher_raw: a single transient 5xx/000 mid-wait must not abort the whole
  # run -- the registration manifest is already applied to the downstream
  # cluster at this point, so keep polling until TIMEOUT. Only die at the
  # bound, and only when the *last* poll itself failed (never got a clean read
  # to check status.ready) -- a clean 200 with ready=false at the bound is not
  # an error, just a cluster that is still provisioning, so that case stays a
  # WARNING with exit 0 as before.
  wait_start=$(date +%s)
  READY=false
  while :; do
    rancher_raw GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}"
    if [[ "$HTTP_STATUS" == "200" ]]; then
      READY=$(printf '%s' "$HTTP_BODY" | jq -r '.status.ready // false')
      [[ "$READY" == "true" ]] && break
    fi
    now=$(date +%s)
    if (( now - wait_start >= TIMEOUT )); then
      if [[ "$HTTP_STATUS" != "200" ]]; then
        die "Timed out waiting for cluster '${CLUSTER_NAME}' to report ready: Rancher stopped answering cleanly (last HTTP ${HTTP_STATUS}: $(body_excerpt "$HTTP_BODY")). The provisioning cluster '${CLUSTER_NAME}' and its registration manifest were already applied -- re-running this script will resume, or check the Rancher UI directly."
      fi
      echo "WARNING: cluster '${CLUSTER_NAME}' was not ready after ${TIMEOUT}s. Check the Rancher UI -- registration may still complete." >&2
      break
    fi
    sleep 5
  done
  if [[ "$READY" == "true" ]]; then
    echo "==> Cluster '${CLUSTER_NAME}' is ready."
  fi
fi

echo "==> Rancher UI: ${NORM_MGMT_URL}/dashboard/c/${CLUSTER_ID}/explorer"
