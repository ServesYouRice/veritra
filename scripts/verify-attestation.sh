#!/usr/bin/env sh
# L3-2: check a Veritra server's attestation report (docs/operations.md,
# "Confidential VM (optional)"). POSIX sh plus openssl, curl, od, dd and awk;
# no verifier library.
#
# It fetches a report for a fresh nonce from GET /api/v1/attestation over a
# TLS connection pinned to the key it first saw, then checks:
#   - the report is an AMD SEV-SNP report (TDX reports are refused: not
#     checked by this script yet);
#   - the VCEK certificate chains to the given AMD root (ARK), whose SHA-256
#     the caller supplies, through the given ASK;
#   - the VCEK is for the chip named in the report, and its key signed it;
#   - the guest policy does not allow debugging;
#   - the report data is SHA-512("veritra-attest-v1" || nonce || SHA-256 of
#     the TLS public key this script connected to), so a report relayed from
#     another machine fails;
#   - the launch measurement equals the expected one for the release.
# It prints "matches release <name>" or "does not match: <reason>". It does
# not check a minimum firmware (TCB) version; it prints the reported one.
#
# Exit codes: 0 matches, 1 does not match, 2 usage or local error,
# 3 report kind not checked by this script (TDX).
set -eu

usage() {
  cat >&2 <<'EOF'
usage: verify-attestation.sh --release NAME --measurement HEX
         --ark ARK.pem --ark-sha256 HEX --ask ASK.pem --vcek VCEK.pem
         [--cacert CA.pem] https://HOST[:PORT][/PATH]
       verify-attestation.sh ... --response FILE --nonce HEX --tls-cert CERT.pem
         (checks a recorded response instead of fetching one)

  --release      name printed on a match
  --measurement  expected launch measurement, 96 hex characters
  --ark          AMD root key certificate (PEM or DER)
  --ark-sha256   expected SHA-256 of the ARK certificate (DER), 64 hex
  --ask          AMD SEV key certificate (PEM or DER)
  --vcek         VCEK certificate for the chip and TCB (PEM or DER)
  --cacert       CA bundle for the TLS connection (default: system store)
EOF
  exit 2
}

local_error() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

no_match() {
  printf 'does not match: %s\n' "$1"
  exit 1
}

release=''
measurement=''
ark=''
ark_sha256=''
ask=''
vcek=''
cacert=''
response=''
nonce_hex=''
tls_cert=''
url=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release | --measurement | --ark | --ark-sha256 | --ask | --vcek | \
      --cacert | --response | --nonce | --tls-cert)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --release) release=$2 ;;
        --measurement) measurement=$2 ;;
        --ark) ark=$2 ;;
        --ark-sha256) ark_sha256=$2 ;;
        --ask) ask=$2 ;;
        --vcek) vcek=$2 ;;
        --cacert) cacert=$2 ;;
        --response) response=$2 ;;
        --nonce) nonce_hex=$2 ;;
        --tls-cert) tls_cert=$2 ;;
      esac
      shift 2
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [ -z "$url" ] || usage
      url=$1
      shift
      ;;
  esac
done

lower() { printf '%s' "$1" | tr 'A-F' 'a-f' | tr -d ':'; }

is_hex() {
  # is_hex VALUE LENGTH
  [ "${#1}" -eq "$2" ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}

[ -n "$release" ] && [ -n "$ark" ] && [ -n "$ask" ] && [ -n "$vcek" ] || usage
case "$release" in *[!A-Za-z0-9._+-]*) local_error 'release name: use letters, digits and . _ + -' ;; esac
measurement=$(lower "$measurement")
ark_sha256=$(lower "$ark_sha256")
is_hex "$measurement" 96 || local_error '--measurement needs 96 hex characters'
is_hex "$ark_sha256" 64 || local_error '--ark-sha256 needs 64 hex characters'
for file in "$ark" "$ask" "$vcek"; do
  [ -r "$file" ] || local_error "cannot read $file"
done
if [ -n "$response" ]; then
  [ -z "$url" ] || usage
  [ -r "$response" ] || local_error "cannot read $response"
  [ -r "$tls_cert" ] || local_error '--response needs a readable --tls-cert'
  nonce_hex=$(lower "$nonce_hex")
  is_hex "$nonce_hex" 64 || local_error '--response needs --nonce of 64 hex characters'
else
  [ -n "$url" ] || usage
  [ -z "$nonce_hex" ] && [ -z "$tls_cert" ] || usage
fi

command -v openssl >/dev/null 2>&1 || local_error 'openssl is required'
if [ -z "$response" ]; then
  command -v curl >/dev/null 2>&1 || local_error 'curl is required'
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

hex_of() { od -An -tx1 -v "$1" | tr -d ' \n'; }
slice() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tx1 -v | tr -d ' \n'; }

hex_to_file() {
  # hex_to_file HEX FILE: writes the bytes without xxd (octal printf escapes).
  # shellcheck disable=SC2059
  printf "$(printf '%s' "$1" | awk '{
    digits = "0123456789abcdef"
    for (i = 1; i <= length($0); i += 2) {
      hi = index(digits, substr($0, i, 1)) - 1
      lo = index(digits, substr($0, i + 1, 1)) - 1
      printf "\\%03o", hi * 16 + lo
    }
  }')" > "$2"
}

reverse_hex() {
  # Little-endian hex to big-endian hex, leading zero bytes dropped.
  printf '%s' "$1" | awk '{
    out = ""
    for (i = length($0) - 1; i >= 1; i -= 2) out = out substr($0, i, 2)
    sub(/^(00)+/, "", out)
    if (out == "") out = "00"
    print out
  }'
}

cert_pem() {
  # cert_pem IN OUT: accepts PEM or DER.
  if ! openssl x509 -in "$1" -out "$2" >/dev/null 2>&1 &&
    ! openssl x509 -inform DER -in "$1" -out "$2" >/dev/null 2>&1; then
    local_error "$1 is not an X.509 certificate"
  fi
}

spki_sha256() {
  # spki_sha256 CERT.pem OUT: SHA-256 of the DER SubjectPublicKeyInfo.
  openssl x509 -in "$1" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform DER 2>/dev/null |
    openssl dgst -sha256 -binary > "$2" 2>/dev/null
  [ "$(wc -c < "$2" | tr -d ' ')" -eq 32 ] || local_error 'cannot read the TLS public key'
}

# 1. The TLS key and the response.
if [ -n "$response" ]; then
  cert_pem "$tls_cert" "$work/server.pem"
  spki_sha256 "$work/server.pem" "$work/spki.sha256"
  hex_to_file "$nonce_hex" "$work/nonce.bin"
  cp "$response" "$work/response.json"
else
  case "$url" in
    https://*) ;;
    *) local_error 'the URL must start with https://' ;;
  esac
  rest=${url#https://}
  hostport=${rest%%/*}
  path=''
  case "$rest" in */*) path="/${rest#*/}" ;; esac
  path=${path%/}
  host=${hostport%%:*}
  port=443
  case "$hostport" in *:*) port=${hostport##*:} ;; esac
  case "$host$port" in *[!A-Za-z0-9.-]* | '') local_error 'unsupported host or port in the URL' ;; esac
  if ! openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null |
    openssl x509 -out "$work/server.pem" >/dev/null 2>&1; then
    no_match "no TLS certificate from $host:$port"
  fi
  spki_sha256 "$work/server.pem" "$work/spki.sha256"
  pin=$(base64 < "$work/spki.sha256" | tr -d '\n')
  openssl rand 32 > "$work/nonce.bin" 2>/dev/null
  nonce_hex=$(hex_of "$work/nonce.bin")
  set -- --silent --show-error --fail --max-time 30 --proto =https \
    --pinnedpubkey "sha256//$pin" --output "$work/response.json"
  [ -z "$cacert" ] || set -- "$@" --cacert "$cacert"
  status=0
  curl "$@" "https://$hostport$path/api/v1/attestation?nonce=$nonce_hex" 2>/dev/null || status=$?
  case "$status" in
    0) ;;
    90) no_match 'the TLS key changed between the two connections' ;;
    22) no_match 'the server gave no report (attestation off, or an error)' ;;
    *) no_match "the report could not be fetched (curl exit $status)" ;;
  esac
fi

json=$(tr -d '\r\n' < "$work/response.json")
field() { printf '%s' "$json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"; }
[ "$(field format)" = 'veritra-attest-v1' ] || no_match 'not a veritra-attest-v1 response'
kind=$(field kind)
case "$kind" in
  sev_guest | sev-snp) ;;
  tdx_guest | tdx)
    printf 'not checked: TDX reports are not verified by this script yet\n'
    exit 3
    ;;
  *) no_match 'unknown report kind' ;;
esac
field report | base64 -d > "$work/report.bin" 2>/dev/null || no_match 'the report is not base64'

# 2. The report (AMD SEV-SNP ABI, ATTESTATION_REPORT, 0x4A0 bytes).
[ "$(wc -c < "$work/report.bin" | tr -d ' ')" -eq 1184 ] || no_match 'the report is not 1184 bytes'
version=$(reverse_hex "$(slice "$work/report.bin" 0 4)")
case "$version" in 00 | 01) no_match 'report version below 2' ;; esac
[ "$(slice "$work/report.bin" 52 4)" = '01000000' ] || no_match 'the signature is not ECDSA P-384 with SHA-384'
# Policy bit 19 (DEBUG) lives in byte 0x0A, bit 3.
policy_debug=$(slice "$work/report.bin" 10 1)
case "$policy_debug" in
  [0-9a-f][89a-f]) no_match 'the guest policy allows debugging' ;;
esac

# 3. The certificate chain.
cert_pem "$ark" "$work/ark.pem"
cert_pem "$ask" "$work/ask.pem"
cert_pem "$vcek" "$work/vcek.pem"
openssl x509 -in "$work/ark.pem" -outform DER -out "$work/ark.der" 2>/dev/null
openssl dgst -sha256 -binary -out "$work/ark.sha256" "$work/ark.der" 2>/dev/null
[ "$(hex_of "$work/ark.sha256")" = "$ark_sha256" ] || no_match 'the ARK is not the expected AMD root'
openssl verify -CAfile "$work/ark.pem" "$work/ark.pem" >/dev/null 2>&1 ||
  no_match 'the ARK is not a valid self-signed root'
openssl verify -CAfile "$work/ark.pem" -untrusted "$work/ask.pem" "$work/vcek.pem" >/dev/null 2>&1 ||
  no_match 'the VCEK does not chain to the ARK through the ASK'

# The VCEK names its chip in extension hwID (1.3.6.1.4.1.3704.1.4), either
# as the 64 raw bytes or wrapped in an OCTET STRING.
hwid=$(openssl asn1parse -in "$work/vcek.pem" 2>/dev/null | awk '
  found && /HEX DUMP/ { sub(/.*\[HEX DUMP\]:/, ""); print tolower($0); exit }
  /:1\.3\.6\.1\.4\.1\.3704\.1\.4$/ { found = 1 }')
case "$hwid" in 0440*) [ "${#hwid}" -ne 132 ] || hwid=${hwid#0440} ;; esac
[ -n "$hwid" ] && [ "$hwid" = "$(slice "$work/report.bin" 416 64)" ] ||
  no_match 'the VCEK is not for the chip in the report'

# 4. The signature: r and s are 72-byte little-endian at 0x2A0 and 0x2E8,
# over bytes 0x000 to 0x29F.
{
  printf 'asn1=SEQUENCE:sig\n[sig]\n'
  printf 'r=INTEGER:0x%s\n' "$(reverse_hex "$(slice "$work/report.bin" 672 72)")"
  printf 's=INTEGER:0x%s\n' "$(reverse_hex "$(slice "$work/report.bin" 744 72)")"
} > "$work/sig.cnf"
openssl asn1parse -genconf "$work/sig.cnf" -out "$work/sig.der" -noout >/dev/null 2>&1 ||
  local_error 'cannot encode the signature'
dd if="$work/report.bin" of="$work/body.bin" bs=672 count=1 2>/dev/null
openssl x509 -in "$work/vcek.pem" -pubkey -noout > "$work/vcek.pub" 2>/dev/null
openssl dgst -sha384 -verify "$work/vcek.pub" -signature "$work/sig.der" "$work/body.bin" >/dev/null 2>&1 ||
  no_match 'the report signature does not verify with the VCEK'

# 5. The binding to this nonce and this TLS key.
{
  printf '%s' 'veritra-attest-v1'
  cat "$work/nonce.bin" "$work/spki.sha256"
} | openssl dgst -sha512 -binary > "$work/expected-data.bin" 2>/dev/null
[ "$(slice "$work/report.bin" 80 64)" = "$(hex_of "$work/expected-data.bin")" ] ||
  no_match 'the report is not for this nonce and TLS key (relayed or replayed)'

# 6. The measurement.
reported=$(slice "$work/report.bin" 144 48)
printf 'reported TCB: %s\n' "$(slice "$work/report.bin" 384 8)"
printf 'measurement: %s\n' "$reported"
[ "$reported" = "$measurement" ] || no_match "the measurement is not the one expected for release $release"
printf 'matches release %s\n' "$release"
