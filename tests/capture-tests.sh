# Offline checks for the capture analyzer. Sourced by run.sh.
export project

mf_cap() { # session-fixture
    bash "$project/tests/capture/analyze.sh" --endpoint 203.0.113.5:51820 \
        --local 192.0.2.10 --local 2001:db8::10 --local fe80::10 --text \
        "$project/tests/capture/fixtures/baseline.txt" "$project/tests/capture/fixtures/$1" 2>&1
}
mf_cap_rc() { mf_cap "$1" >/dev/null; }

check 'capture: endpoint plus baseline traffic passes' mf_cap_rc session-pass.txt
check 'capture: a DNS packet to another resolver fails and is named' \
    bash -c 'source "$1"; out=$(mf_cap session-dns.txt) && exit 1; [[ $out == *"198.51.100.7 port 53"* ]]' _ <(declare -f mf_cap)
check 'capture: outbound IPv6 outside the baseline fails' \
    bash -c 'source "$1"; out=$(mf_cap session-v6.txt) && exit 1; [[ $out == *"v6 tcp 2001:db8::99"* ]]' _ <(declare -f mf_cap)
check 'capture: a session with no endpoint packets is inconclusive, not a pass' \
    bash -c 'source "$1"; out=$(mf_cap session-silent.txt) && exit 1; [[ $out == *inconclusive* ]]' _ <(declare -f mf_cap)
check 'capture: a bad endpoint is a usage error' \
    bash -c '! bash "$1/tests/capture/analyze.sh" --endpoint nonsense --local 192.0.2.10 --text a b >/dev/null 2>&1' _ "$project"
check 'capture: the profile option reads only the Endpoint line' \
    bash -c 'f=$(mktemp); printf "[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n[Peer]\nEndpoint = 203.0.113.5:51820\n" > "$f"
        out=$(bash "$1/tests/capture/analyze.sh" --profile "$f" --local 192.0.2.10 --text "$1/tests/capture/fixtures/baseline.txt" "$1/tests/capture/fixtures/session-pass.txt" 2>&1); rc=$?
        rm -f -- "$f"; [[ $rc == 0 && $out != *AAAA* ]]' _ "$project"
