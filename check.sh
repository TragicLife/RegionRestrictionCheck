#!/bin/bash
Font_Black="\033[30m"
Font_Red="\033[31m"
Font_Green="\033[32m"
Font_Yellow="\033[33m"
Font_Blue="\033[34m"
Font_Purple="\033[35m"
Font_SkyBlue="\033[36m"
Font_White="\033[37m"
Font_Suffix="\033[0m"

while getopts ":I:M:EX:P:F:S:R:C:D:" optname; do
    case "$optname" in
        "I")
            iface="$OPTARG"
            useNIC="--interface $iface"
        ;;
        "M")
            if [[ "$OPTARG" == "4" ]]; then
                NetworkType=4
                elif [[ "$OPTARG" == "6" ]]; then
                NetworkType=6
            fi
        ;;
        "E")
            language="e"
        ;;
        "X")
            XIP="$OPTARG"
            xForward="--header X-Forwarded-For:$XIP"
        ;;
        "P")
            proxy="$OPTARG"
            usePROXY="-x $proxy"
        ;;
        "F")
            func="$OPTARG"
        ;;
        "S")
            Stype="$OPTARG"
        ;;
        "R")
            Resolve="$OPTARG"
            resolve="--resolve *:443:$Resolve"
        ;;
        "C")
            Curl="$OPTARG"
        ;;
        "D")
            Dns="$OPTARG"
            dns="--dns-servers $Dns"
        ;;
        ":")
            echo "Unknown error while processing options"
            exit 1
        ;;
    esac
    
done

# -C: curl program to run, optionally with its own arguments
read -r -a curl_bin <<<"${Curl:-curl}"

if [ -z "$iface" ]; then
    useNIC=""
fi

if [ -z "$XIP" ]; then
    xForward=""
fi

if [ -z "$proxy" ]; then
    usePROXY=""
fi

if [ -z "$Resolve" ]; then
    resolve=""
fi

if [ -z "$Dns" ]; then
    dns=""
fi

# Exercise every grep feature this script relies on. Behaviour is tested rather
# than guessed from the OS or binary name: BusyBox's grep depends on its build
# options, macOS ships BSD grep, and either may have been replaced by GNU grep.
# Keep this in sync when a test starts using another grep feature. In particular
# stick to POSIX patterns (no -P, \d or \w, no empty alternatives such as "(a|)"),
# put options before the pattern, since not every grep reorders arguments, and
# avoid -w with -o: BusyBox 1.37 finds "a=CN" in "xa=CN" after an earlier match.
# $1: grep command to test
grep_is_capable() {
    local bin="$1"
    command -v "$bin" >/dev/null || return 1

    # -q: exit status only, 1 means "no match" and anything above is an error
    printf 'ABC\n' | command "$bin" -q 'ABC' || return 1
    printf 'ABC\n' | command "$bin" -q 'XYZ'
    [ $? -eq 1 ] || return 1
    # -i, and -E with alternation, groups and intervals
    [ "$(printf 'ABC\n' | command "$bin" -i 'abc')" == "ABC" ] || return 1
    printf 'ABC\n' | command "$bin" -qiE 'xyz|a(b)c' || return 1
    [ "$(printf 'aa\na\n' | command "$bin" -E '^a{2}$')" == "aa" ] || return 1
    # -F: metacharacters are literal
    [ "$(printf 'a.c\nabc\n' | command "$bin" -F 'a.c')" == "a.c" ] || return 1
    # -o: every match on a line is printed on its own line
    [ "$(printf 'x=US y=JP\n' | command "$bin" -Eo '=[A-Z]{2}' | tr -d '\n')" == "=US=JP" ] || return 1
    # Basic regex intervals, and "{" as a plain character in a basic regex
    [ "$(printf 'x=US\n' | command "$bin" -o '[A-Z]\{2\}')" == "US" ] || return 1
    [ "$(printf 'k:{a}\n' | command "$bin" -o '{[^}]*}')" == "{a}" ] || return 1
    # -o with anchors in alternatives, the portable way to match a whole word
    [ "$(printf 'xa=CN a=US\n' | command "$bin" -oE '(^|[^a-z])a=[A-Z]{2}($|[^A-Z])' | tr -d ' ')" == "a=US" ] || return 1
} 2>/dev/null

# Use the first capable grep, so a default one that is too limited can be
# replaced by GNU grep installed under another name. A function, not an alias,
# so that it also applies inside command substitutions and background jobs.
checkGrep() {
    local candidate
    for candidate in grep ggrep gnugrep; do
        if grep_is_capable "$candidate"; then
            if [ "$candidate" != "grep" ]; then
                eval "grep() { command $candidate \"\$@\"; }"
            fi
            return 0
        fi
    done
    echo -e "${Font_Red}The grep on this system lacks features this script needs, please install GNU grep and try again.${Font_Suffix}" >&2
    exit 1
}
checkGrep

# Wraps curl while a check runs under run_check: if any response body is a Cloudflare WAF
# block page, a marker is left in $CF_WAF_MARK so run_check can rewrite the check's result.
curl() {
    if [ -z "$CF_WAF_MARK" ]; then
        command "${curl_bin[@]}" "$@"
        return
    fi
    local args=() outfile="" tmpout="" rc
    while [ $# -gt 0 ]; do
        if [[ "$1" == "-o" || "$1" == "--output" ]] && [ $# -gt 1 ]; then
            outfile="$2"
            if [[ "$outfile" == "/dev/null" ]]; then
                tmpout=$(mktemp)
                args+=("$1" "$tmpout")
            else
                args+=("$1" "$2")
            fi
            shift 2
            continue
        fi
        args+=("$1")
        shift
    done
    if [ -n "$tmpout" ]; then
        # -f discards the body of an HTTP error, which is where a WAF page would be.
        # The output is unused here and %{http_code} is the same without it.
        local i
        for i in "${!args[@]}"; do
            if [[ "${args[i]}" == "--fail" ]]; then
                unset "args[i]"
            elif [[ "${args[i]}" =~ ^-[A-Za-z0-9]*f[A-Za-z0-9]*$ ]]; then
                args[i]="${args[i]//f/}"
                [[ "${args[i]}" == "-" ]] && unset "args[i]"
            fi
        done
    fi
    if [ -n "$outfile" ]; then
        command "${curl_bin[@]}" "${args[@]}"
        rc=$?
        if [ -n "$tmpout" ]; then
            grep -q '<title>Attention Required! | Cloudflare</title>' "$tmpout" 2>/dev/null && echo 1 >"$CF_WAF_MARK"
            rm -f "$tmpout"
        elif [ -f "$outfile" ]; then
            grep -q '<title>Attention Required! | Cloudflare</title>' "$outfile" 2>/dev/null && echo 1 >"$CF_WAF_MARK"
        fi
        return $rc
    fi
    local out
    out=$(command "${curl_bin[@]}" "${args[@]}")
    rc=$?
    if [[ "$out" == *'<title>Attention Required! | Cloudflare</title>'* ]]; then
        echo 1 >"$CF_WAF_MARK"
    fi
    printf '%s\n' "$out"
    return $rc
}

curlArgs="$useNIC $usePROXY $xForward $resolve $dns --max-time 10"
UA_Browser="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36 Edg/112.0.1722.64"
UA_Dalvik="Dalvik/2.1.0 (Linux; U; Android 9; ALP-AL00 Build/HUAWEIALP-AL00)"
UA_SecCHUA='"Chromium";v="112", "Microsoft Edge";v="112", "Not:A-Brand";v="99"'
Media_Cookie=$(curl -s --retry 3 --max-time 10 "https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/cookies" &)
IATACode=$(curl -s --retry 3 --max-time 10 "https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/reference/IATACode.txt" &)

checkOS() {
    ifTermux=$(echo $PWD | grep termux)
    ifMacOS=$(uname -a | grep Darwin)
    if [ -n "$ifTermux" ]; then
        os_version=Termux
        is_termux=1
        elif [ -n "$ifMacOS" ]; then
        os_version=MacOS
        is_macos=1
    else
        os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
    fi
    
    if [[ "$os_version" == "2004" ]] || [[ "$os_version" == "10" ]] || [[ "$os_version" == "11" ]]; then
        is_windows=1
        ssll="-k --ciphers DEFAULT@SECLEVEL=1"
    fi
    
    # Termux and macOS first: both have an "apt" command that is not Debian's
    # (on macOS, /usr/bin/apt is a Java tool).
    if [[ "$os_version" == "Termux" ]]; then
        InstallMethod="pkg"
        elif [[ "$os_version" == "MacOS" ]]; then
        InstallMethod="brew"
        elif [ "$(which apt 2>/dev/null)" ]; then
        InstallMethod="apt"
        is_debian=1
        elif [ "$(which dnf 2>/dev/null)" ] || [ "$(which yum 2>/dev/null)" ]; then
        InstallMethod="yum"
        is_redhat=1
    fi
}
checkOS

checkCPU() {
    CPUArch=$(uname -m)
    if [[ "$CPUArch" == "aarch64" ]]; then
        arch=_arm64
        elif [[ "$CPUArch" == "i686" ]]; then
        arch=_i686
        elif [[ "$CPUArch" == "arm" ]]; then
        arch=_arm
        elif [[ "$CPUArch" == "x86_64" ]] && [ -n "$ifMacOS" ]; then
        arch=_darwin
    fi
}
checkCPU

checkDependencies() {
    
    if ! command -v jq &>/dev/null; then
        if [ "$is_debian" == 1 ]; then
            echo -e "${Font_Green}Installing jq${Font_Suffix}"
            $InstallMethod update >/dev/null 2>&1
            $InstallMethod install jq -y >/dev/null 2>&1
            elif [ "$is_redhat" == 1 ]; then
            echo -e "${Font_Green}Installing jq${Font_Suffix}"
            $InstallMethod makecache >/dev/null 2>&1
            $InstallMethod install jq -y >/dev/null 2>&1
            elif [ "$is_termux" == 1 ]; then
            echo -e "${Font_Green}Installing jq${Font_Suffix}"
            $InstallMethod update -y >/dev/null 2>&1
            $InstallMethod install jq -y >/dev/null 2>&1
            elif [ "$is_macos" == 1 ] && command -v brew &>/dev/null; then
            echo -e "${Font_Green}Installing jq${Font_Suffix}"
            $InstallMethod install jq
        fi
    fi
    
    if [ "$is_macos" == 1 ] && command -v brew &>/dev/null; then
        if ! command -v md5sum &>/dev/null; then
            echo -e "${Font_Green}Installing md5sha1sum${Font_Suffix}"
            $InstallMethod install md5sha1sum
        fi
    fi

    if ! command -v jq &>/dev/null; then
        echo -e "${Font_Red}jq is required but could not be installed automatically, please install jq and try again.${Font_Suffix}" >&2
        exit 1
    fi
}
checkDependencies

# Run a jq filter on stdin. Services often answer with HTML (block pages,
# captchas) or an empty body instead of JSON, so jq's parse errors are not
# printed into the result table; the caller just gets empty output and a
# non-zero status. Set DEBUG=1 to see which test received what.
json_query() {
    local input output
    input=$(cat)
    if ! output=$(printf '%s' "$input" | jq "$@" 2>/dev/null); then
        if [ -n "$DEBUG" ]; then
            echo "[${FUNCNAME[1]:-main}] jq '$*': response is not valid JSON: $(printf '%s' "$input" | head -c 200 | tr -d '\n')" >&2
        fi
        return 1
    fi
    printf '%s\n' "$output"
}

# Print a string without its first and last characters. Replaces
# ${var:offset:-n}, which needs bash 4.2 while macOS ships bash 3.2. Prints
# nothing when the string is too short, e.g. when the value was not found.
# $1: string, $2: characters to drop from the start, $3: from the end
trim_chars() {
    local length=$((${#1} - $2 - $3))
    if [ "$length" -gt 0 ]; then
        printf '%s' "${1:$2:$length}"
    fi
}

# Print a string in upper case. Replaces ${var^^}, which needs bash 4 while macOS
# ships bash 3.2. Only ASCII letters are converted, which covers region codes.
# $1: string
to_upper() {
    printf '%s' "$1" | tr 'a-z' 'A-Z'
}

# Print the first IPv4/IPv6 address of a host using the system resolver.
# curl is used so this works without GNU getent (macOS, BusyBox, ...).
# $1: 4 or 6, $2: host name
resolve_ip() {
    curl $useNIC -${1} -s -o /dev/null --connect-timeout 2 --max-time 3 -w '%{remote_ip}' "http://${2}/" 2>/dev/null
}

# Return success when a host has an IPv6 (AAAA) address via the system resolver.
# curl exits with code 6 only when the host name cannot be resolved.
# $1: host name or URL
has_ipv6_address() {
    local host="${1#*://}"
    host="${host%%/*}"
    curl $useNIC -6 -s -o /dev/null --connect-timeout 2 --max-time 3 "http://${host}/" >/dev/null 2>&1
    [ $? -ne 6 ]
}

# Print a message for the calling test to stderr, only when DEBUG=1 is set.
# $*: message
debug_log() {
    [ -z "$DEBUG" ] || echo "[${FUNCNAME[1]}] $*" >&2
}

# Print the result line for a request that failed at the network level.
# On IPv6, a service without an AAAA record is reported as not supporting IPv6.
# $1: label including the tab padding, e.g. "Abema.TV:\t\t\t\t"
# $2: IP version (4 or 6), $3: host name or URL that was requested
# $4: optional detail appended to the failure, e.g. "[2]"
print_network_failure() {
    if [[ "$2" == "6" ]] && ! has_ipv6_address "$3"; then
        echo -n -e "\r ${1}${Font_Yellow}IPv6 Not Supported${Font_Suffix}\n"
    else
        echo -n -e "\r ${1}${Font_Red}Failed (Network Connection${4})${Font_Suffix}\n"
    fi
}

# Runs a check function; if any of its requests hit a Cloudflare WAF block page,
# its result lines are replaced with "Blocked by WAF".
# $1: check function, remaining arguments are passed through (usually the IP version)
run_check() {
    local CF_WAF_MARK
    CF_WAF_MARK=$(mktemp) || { "$@"; return; }
    local output
    output=$("$@")
    if [ -s "$CF_WAF_MARK" ]; then
        local line
        while IFS= read -r line; do
            if [[ "$line" == *$'\033'* ]]; then
                printf '%s%b\n' "${line%%$'\033'*}" "${Font_Red}No  (Blocked by WAF)${Font_Suffix}"
            elif [ -n "$line" ]; then
                printf '%s\n' "$line"
            fi
        done <<<"$output"
    elif [ -n "$output" ]; then
        printf '%s\n' "$output"
    fi
    rm -f "$CF_WAF_MARK"
}
# Print the public IPv4/IPv6 address. The services used serve only one IP version,
# so curl is not forced with -4/-6: behind a VPN (TUN mode, fake-IP DNS) or a proxy
# the local connection can fail for a version the egress still has, or succeed
# through the other one. The next service is tried when one is unreachable before
# concluding that the IP version has no connectivity.
# Set DEBUG=1 to trace each request: curl command, exit code, connected address,
# HTTP status and response. The trace is printed by CheckV4, as the menu clears the
# screen after this runs.
# $1: 4 or 6
get_public_ip() {
    local ip url urls raw rc
    if [[ "$1" == "4" ]]; then
        urls=("https://api4.ipify.org" "https://ipv4.icanhazip.com")
    else
        urls=("https://api6.ipify.org" "https://ipv6.icanhazip.com")
    fi
    for url in "${urls[@]}"; do
        if [ -n "$DEBUG" ]; then
            echo "[get_public_ip] IPv${1}: curl $curlArgs -sS --max-time 5 $url" >&2
            raw=$(curl $curlArgs -sS --max-time 5 --user-agent "${UA_Browser}" -w '\n[remote_ip=%{remote_ip} http_code=%{http_code}]' "$url" 2>&1)
            rc=$?
            echo "[get_public_ip] IPv${1}: exit $rc, response: $(printf '%s' "$raw" | head -c 300 | tr '\n' ' ')" >&2
            raw=$(printf '%s\n' "$raw" | sed '$d')
        else
            raw=$(curl $curlArgs -s --max-time 5 --user-agent "${UA_Browser}" "$url" 2>/dev/null)
        fi
        ip=$(printf '%s' "$raw" | tr -d ' \t\n\r\v\f')
        if [[ "$1" == "4" && "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$1" == "6" && "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]]; then
            [ -n "$DEBUG" ] && echo "[get_public_ip] IPv${1}: using $ip" >&2
            echo "$ip"
            return
        fi
        [ -n "$DEBUG" ] && echo "[get_public_ip] IPv${1}: '$ip' is not an IPv${1} address" >&2
    done
    [ -n "$DEBUG" ] && echo "[get_public_ip] IPv${1}: no address found" >&2
}

if [ -z "$func" ]; then
    ip_fetch_trace=/dev/null
    if [ -n "$DEBUG" ]; then
        ip_fetch_trace=$(mktemp)
    fi
    local_ipv4=$(get_public_ip 4 2>>"$ip_fetch_trace")
    local_ipv6=$(get_public_ip 6 2>>"$ip_fetch_trace")
    # bgptools_v4=$(curl $curlArgs -s -4 --max-time 10 --user-agent "${UA_Browser}" "https://v4.bgp.tools/whoami-not-for-robots" &)
    # bgptools_v6=$(curl $curlArgs -s -6 --max-time 10 --user-agent "${UA_Browser}" "https://v6.bgp.tools/whoami-not-for-robots" &)
    ripe_stat_v4=$(curl $curlArgs -s --max-time 10 "https://stat.ripe.net/data/prefix-overview/data.json?resource=$local_ipv4" &)
    ripe_stat_v6=$(curl $curlArgs -s --max-time 10 "https://stat.ripe.net/data/prefix-overview/data.json?resource=$local_ipv6" &)
    wait
    local_isp4=$(echo $ripe_stat_v4 | json_query .data.asns[0].holder | tr -d '"')
    local_as4=$(echo $ripe_stat_v4 | json_query .data.asns[0].asn | tr -d '"')
    local_ipv4_asterisk=$(echo $ripe_stat_v4 | json_query .data.resource | tr -d '"')
    local_isp6=$(echo $ripe_stat_v6 | json_query .data.asns[0].holder | tr -d '"')
    local_as6=$(echo $ripe_stat_v6 | json_query .data.asns[0].asn | tr -d '"')
    local_ipv6_asterisk=$(echo $ripe_stat_v6 | json_query .data.resource | tr -d '"')
    wait
fi


ShowRegion() {
    echo -e "${Font_Yellow} ---${1}---${Font_Suffix}"
}

function detect_isp() {
    local lan_ip=$(echo "$1" | grep -Eo "^(10\.[0-9]{1,3}\.[0-9]{1,3}\.((0/([89]|1[0-9]|2[0-9]|3[012]))|([0-9]{1,3})))|(172\.(1[6789]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}(/(1[6789]|2[0-9]|3[012]))?)|(192\.168\.[0-9]{1,3}\.[0-9]{1,3}(/(1[6789]|2[0-9]|3[012]))?)$")
    if [ -n "$lan_ip" ]; then
        echo "LAN"
        return
    else
        local res=$(curl $curlArgs --user-agent "${UA_Browser}" -s --max-time 20 "https://api.ip.sb/geoip/$1" | json_query ".isp" | tr -d '"' )
        echo "$res"
        return
    fi
}

function GameTest_Steam() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://store.steampowered.com/app/761830" 2>&1 | grep priceCurrency | cut -d '"' -f4)

    if [ ! -n "$result" ]; then
        print_network_failure "Steam Currency:\t\t\t" "$1" "store.steampowered.com"
    else
        echo -n -e "\r Steam Currency:\t\t\t${Font_Green}${result}${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_HBONow() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 --write-out "%{url_effective}\n" --output /dev/null "https://play.hbonow.com/" 2>&1)
    if [[ "$result" != "curl"* ]]; then
        if [ "${result}" = "https://play.hbonow.com" ] || [ "${result}" = "https://play.hbonow.com/" ]; then
            echo -n -e "\r HBO Now:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        elif [ "${result}" = "http://hbogeo.cust.footprint.net/hbonow/geo.html" ] || [ "${result}" = "http://geocust.hbonow.com/hbonow/geo.html" ]; then
            echo -n -e "\r HBO Now:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        fi
    else
        print_network_failure "HBO Now:\t\t\t\t" "$1" "play.hbonow.com"
    fi
}

function MediaUnlockTest_BahamutAnime() {
    local tmpdeviceid=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" --max-time 10 -fsSL "https://ani.gamer.com.tw/ajax/getdeviceid.php" --cookie-jar bahamut_cookie.txt 2>&1)
    if [[ "$tmpdeviceid" == "curl"* ]]; then
        print_network_failure "Bahamut Anime:\t\t\t\t" "$1" "ani.gamer.com.tw"
        rm -f bahamut_cookie.txt
        return
    fi
    local tempdeviceid=$(echo $tmpdeviceid | json_query . | grep 'deviceid' | awk '{print $2}' | tr -d '"' )
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" --max-time 10 -fsSL "https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn=38832&device=${tempdeviceid}" -b bahamut_cookie.txt 2>&1)
    local tmpresult2=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" --max-time 10 -fsSL "https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn=37783&device=${tempdeviceid}" -b bahamut_cookie.txt 2>&1)
    if [[ "$tmpresult" == "curl"* ]] || [[ "$tmpresult2" == "curl"* ]]; then
        print_network_failure "Bahamut Anime:\t\t\t\t" "$1" "ani.gamer.com.tw"
        return
    fi
    rm -f bahamut_cookie.txt
    local result=$(echo $tmpresult | json_query . | grep 'animeSn')
    local result2=$(echo $tmpresult2 | json_query . | grep 'animeSn')
    if [ -n "$result" ] && [ -n "$result2" ]; then
        echo -n -e "\r Bahamut Anime:\t\t\t\t${Font_Green}Yes (Region: TW)${Font_Suffix}\n"
    elif [ -n "$result2" ]; then
        echo -n -e "\r Bahamut Anime:\t\t\t\t${Font_Green}Yes (Region: HK/MO)${Font_Suffix}\n"
    else
        echo -n -e "\r Bahamut Anime:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_BilibiliHKMCTW() {
    local randsession="$(cat /dev/urandom | head -n 32 | md5sum | head -c 32)"
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&session=${randsession}&module=bangumi" 2>&1)
    if [[ "$result" != "curl"* ]]; then
        local result="$(echo "${result}" | json_query . | grep '"code"' | head -1 | awk '{print $2}' | cut -d ',' -f1)"
        if [ "${result}" = "0" ]; then
            echo -n -e "\r BiliBili Hongkong/Macau/Taiwan:\t${Font_Green}Yes${Font_Suffix}\n"
        elif [ "${result}" = "-10403" ]; then
            echo -n -e "\r BiliBili Hongkong/Macau/Taiwan:\t${Font_Red}No${Font_Suffix}\n"
        else
            echo -n -e "\r BiliBili Hongkong/Macau/Taiwan:\t${Font_Red}Failed${Font_Suffix} ${Font_SkyBlue}(${result})${Font_Suffix}\n"
        fi
    else
        print_network_failure "BiliBili Hongkong/Macau/Taiwan:\t" "$1" "api.bilibili.com"
    fi
}

# Streaming unlock test - Bilibili Taiwan only
function MediaUnlockTest_BilibiliTW() {
    local randsession="$(cat /dev/urandom | head -n 32 | md5sum | head -c 32)"
    # Try to get a successful result
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://api.bilibili.com/pgc/player/web/playurl?avid=50762638&cid=100279344&qn=0&type=&otype=json&ep_id=268176&fourk=1&fnver=0&fnval=16&session=${randsession}&module=bangumi" 2>&1)
    if [[ "$result" != "curl"* ]]; then
        local result="$(echo "${result}" | json_query . | grep '"code"' | head -1 | awk '{print $2}' | cut -d ',' -f1)"
        if [ "${result}" = "0" ]; then
            echo -n -e "\r Bilibili Taiwan Only:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        elif [ "${result}" = "-10403" ]; then
            echo -n -e "\r Bilibili Taiwan Only:\t\t\t${Font_Red}No${Font_Suffix}\n"
        else
            echo -n -e "\r Bilibili Taiwan Only:\t\t\t${Font_Red}Failed${Font_Suffix} ${Font_SkyBlue}(${result})${Font_Suffix}\n"
        fi
    else
        print_network_failure "Bilibili Taiwan Only:\t\t\t" "$1" "api.bilibili.com"
    fi
}

# Streaming unlock test - Abema.TV
#
function MediaUnlockTest_AbemaTV_IPTest() {
    local tempresult=$(curl $curlArgs --user-agent "${UA_Dalvik}" -${1} -sSL --max-time 10 "https://api.abema.io/v1/ip/check?device=android" 2>&1)
    if [[ "$tempresult" == "curl"* ]]; then
        print_network_failure "Abema.TV:\t\t\t\t" "$1" "api.abema.io"
        return
    fi

    result=$(echo "$tempresult" | json_query . | grep isoCountryCode | awk '{print $2}' | cut -f2 -d'"')
    if [ -n "$result" ]; then
        if [[ "$result" == "JP" ]]; then
            echo -n -e "\r Abema.TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        else
            echo -n -e "\r Abema.TV:\t\t\t\t${Font_Yellow}Oversea Only (Region: ${result})${Font_Suffix}\n"
        fi
    else
        echo -n -e "\r Abema.TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_PCRJP() {
    local result=$(curl $curlArgs --user-agent "${UA_Dalvik}" -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://api-priconne-redive.cygames.jp/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Princess Connect Re:Dive Japan:\t" "$1" "api-priconne-redive.cygames.jp"
    elif [ "$result" = "404" ]; then
        echo -n -e "\r Princess Connect Re:Dive Japan:\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Princess Connect Re:Dive Japan:\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Princess Connect Re:Dive Japan:\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_UMAJP() {
    local result=$(curl $curlArgs --user-agent "${UA_Dalvik}" -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://api.games.umamusume.jp/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Pretty Derby Japan:\t\t\t" "$1" "api.games.umamusume.jp"
    elif [ "$result" = "404" ]; then
        echo -n -e "\r Pretty Derby Japan:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Pretty Derby Japan:\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Pretty Derby Japan:\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Kancolle() {
    local result=$(curl $curlArgs --user-agent "${UA_Dalvik}" -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "http://w00g.kancolle-server.com/kcscontents/news/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Kancolle Japan:\t\t\t" "$1" "w00g.kancolle-server.com"
    elif [ "$result" = "200" ]; then
        echo -n -e "\r Kancolle Japan:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Kancolle Japan:\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Kancolle Japan:\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_BBCiPLAYER() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsL --max-time 10 "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/bbc_one_london/format/json/jsfunc/JS_callbacks0" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "BBC iPLAYER:\t\t\t\t" "$1" "open.live.bbc.co.uk"
        return
    fi

    result=$(echo $tmpresult | grep 'geolocation')
    if [ -n "$result" ]; then
        echo -n -e "\r BBC iPLAYER:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r BBC iPLAYER:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Netflix() {
    local tmpresult1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 --tlsv1.3 "https://www.netflix.com/title/81280792" 2>&1)
    local tmpresult2=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 --tlsv1.3 "https://www.netflix.com/title/70143836" 2>&1)
    if [[ "$tmpresult1" == "curl"* ]] || [[ "$tmpresult2" == "curl"* ]]; then
        print_network_failure "Netflix:\t\t\t\t" "$1" "www.netflix.com"
        return
    fi
    local result1=$( echo "$tmpresult1" | grep "og:video" )
    local result2=$( echo "$tmpresult2" | grep "og:video" )
    local region1=$( echo -e $(echo "$tmpresult1" | grep 'netflix.reactContext' | awk -F= '{print $2}' | awk -F\; '{print $1}') | tr -d '\000-\037\177' | sed 's/\^[^$]*\$//g' | json_query '.models.geo.data.requestCountry.id' | tr -d '"' )

    if [ -n "$result1" ] || [ -n "$result2" ]; then
        echo -n -e "\r Netflix:\t\t\t\t${Font_Green}Yes (Region: ${region1})${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Netflix:\t\t\t\t${Font_Yellow}Originals Only (Region: ${region1})${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Netflix:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_DisneyPlus() {
    local PreAssertion=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/devices" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -H "content-type: application/json; charset=UTF-8" -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>&1)
    if [[ "$PreAssertion" == "curl"* ]]; then
        print_network_failure "Disney+:\t\t\t\t" "$1" "disney.api.edge.bamgrid.com" "[1]"
        return
    fi

    local assertion=$(echo $PreAssertion | json_query . | grep assertion | cut -f4 -d'"')
    local PreDisneyCookie=$(echo "$Media_Cookie" | sed -n '1p')
    local disneycookie=$(echo $PreDisneyCookie | sed "s/DISNEYASSERTION/${assertion}/g")
    local TokenContent=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/token" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disneycookie" 2>&1)
    if [[ "$TokenContent" == "curl"* ]]; then
        print_network_failure "Disney+:\t\t\t\t" "$1" "disney.api.edge.bamgrid.com" "[2]"
        return
    fi
    local isBanned=$(echo $TokenContent | json_query . | grep 'forbidden-location')
    local is403=$(echo $TokenContent | grep '403 ERROR')

    if [ -n "$isBanned" ] || [ -n "$is403" ]; then
        echo -n -e "\r Disney+:\t\t\t\t${Font_Red}No  (Banned)${Font_Suffix}\n"
        return
    fi

    local fakecontent=$(echo "$Media_Cookie" | sed -n '8p')
    local refreshToken=$(echo $TokenContent | json_query . | grep 'refresh_token' | awk '{print $2}' | cut -f2 -d'"')
    local disneycontent=$(echo $fakecontent | sed "s/ILOVEDISNEY/${refreshToken}/g")
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -X POST -sSL --max-time 10 "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disneycontent" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Disney+:\t\t\t\t" "$1" "disney.api.edge.bamgrid.com" "[3]"
        return
    fi
    # Disney+ can block an IP from its site while bamgrid stays reachable: the API
    # then reports a supported region, but the service is not usable from this IP.
    local previewchecktmp previewrc
    previewchecktmp=$(curl $curlArgs -${1} -s -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://www.disneyplus.com" 2>/dev/null)
    previewrc=$?
    local previewcheck=$(echo $previewchecktmp | grep preview)
    local isUnavailable=$(echo $previewcheck | grep 'unavailable')
    local region=$(echo $tmpresult | json_query . | grep 'countryCode' | cut -f4 -d'"')
    local inSupportedLocation=$(echo $tmpresult | json_query . | grep 'inSupportedLocation' | awk '{print $2}' | cut -f1 -d',')

    # A timeout (28) proves nothing about a block, so it stays a network failure below.
    if [ "$previewrc" -ne 0 ] && [ "$previewrc" -ne 28 ] && [ -n "$region" ] && [[ "$inSupportedLocation" == "true" ]]; then
        echo -n -e "\r Disney+:\t\t\t\t${Font_Red}No  (Region: $region, Site Blocked)${Font_Suffix}\n"
        return
    elif [ "$previewrc" -ne 0 ]; then
        print_network_failure "Disney+:\t\t\t\t" "$1" "www.disneyplus.com" "[4]"
        return
    elif [[ "$region" == "JP" ]]; then
        echo -n -e "\r Disney+:\t\t\t\t${Font_Green}Yes (Region: JP)${Font_Suffix}\n"
        return
    elif [ -n "$region" ] && [[ "$inSupportedLocation" == "false" ]] && [ -z "$isUnavailable" ]; then
        echo -n -e "\r Disney+:\t\t\t\t${Font_Yellow}Available For [Disney+ $region] Soon${Font_Suffix}\n"
        return
    elif [ -n "$region" ] && [ -n "$isUnavailable" ]; then
        echo -n -e "\r Disney+:\t\t\t\t${Font_Red}No  (Unavailable)${Font_Suffix}\n"
        return
    elif [ -n "$region" ] && [[ "$inSupportedLocation" == "true" ]]; then
        echo -n -e "\r Disney+:\t\t\t\t${Font_Green}Yes (Region: $region)${Font_Suffix}\n"
        return
    elif [ -z "$region" ]; then
        echo -n -e "\r Disney+:\t\t\t\t${Font_Red}No  (Unknown)${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Disney+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Dazn() {
    # The website answers 403 to banned IPs before the region API is consulted.
    local httpcode=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://www.dazn.com/" 2>&1)
    if [[ "$httpcode" == "curl"* ]]; then
        print_network_failure "Dazn:\t\t\t\t\t" "$1" "www.dazn.com"
        return
    fi
    if [[ "$httpcode" == "403" ]]; then
        echo -n -e "\r Dazn:\t\t\t\t\t${Font_Red}No  (Banned)${Font_Suffix}\n"
        return
    fi
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://startup.core.indazn.com/v1/main/web?Platform=web&LandingPageKey=generic&Brand=dazn" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Dazn:\t\t\t\t\t" "$1" "startup.core.indazn.com"
        return
    fi
    if [[ "$tmpresult" == *"Security policy has been breached"* ]]; then
        echo -n -e "\r Dazn:\t\t\t\t\t${Font_Red}No  (Banned)${Font_Suffix}\n"
        return
    fi
    # CloudFront also rejects curl's TLS fingerprint regardless of the IP;
    # a Chrome-impersonating curl passed with -C gets through.
    if [[ "$tmpresult" == *"Request blocked."* ]]; then
        echo -n -e "\r Dazn:\t\t\t\t\t${Font_Yellow}Maybe (WAF Blocked)${Font_Suffix}\n"
        return
    fi
    # Anything else that isn't JSON (CloudFront/WAF error pages, etc.)
    if [[ "$tmpresult" != "{"* ]]; then
        echo -n -e "\r Dazn:\t\t\t\t\t${Font_Red}Failed (Unexpected Result)${Font_Suffix}\n"
        return
    fi
    local isAllowed=$(echo "$tmpresult" | json_query .Region.isAllowed)
    local region=$(echo "$tmpresult" | json_query -r .Region.GeolocatedCountry)
    local reason=$(echo "$tmpresult" | json_query -r '.Region.disallowedReason // empty')

    if [[ "$isAllowed" == "true" ]]; then
        echo -n -e "\r Dazn:\t\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    elif [[ "$isAllowed" == "false" ]]; then
        if [ -n "$reason" ]; then
            echo -n -e "\r Dazn:\t\t\t\t\t${Font_Red}No  (${reason})${Font_Suffix}\n"
        else
            echo -n -e "\r Dazn:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        fi
        return
    else
        echo -n -e "\r Dazn:\t\t\t\t\t${Font_Red}Unsupport${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_HuluJP() {
    # id.hulu.jp serves its login page to Japanese IPs, and 403 or a redirect to a "restrict" page to everything else.
    # It resets requests that do not look like a browser navigation, so these headers are required.
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --max-time 10 -o /dev/null -w '%{http_code}_TAG_%{url_effective}\n' "https://id.hulu.jp/" -H 'Accept: */*;q=0.8' -H 'Accept-Language: en-US,en;q=0.5' -H 'Accept-Encoding: none' -H 'Sec-GPC: 1' -H 'Upgrade-Insecure-Requests: 1' -H 'Sec-Fetch-Dest: document' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-User: ?1' -H 'Priority: u=1' 2>/dev/null)
    local httpcode=$(echo "$tmpresult" | awk -F'_TAG_' '{print $1}')
    local urleffective=$(echo "$tmpresult" | awk -F'_TAG_' '{print $2}')

    if [[ "$httpcode" == "000" ]] || [ -z "$httpcode" ]; then
        print_network_failure "Hulu Japan:\t\t\t\t" "$1" "id.hulu.jp"
        return
    fi
    if [[ "$urleffective" == *"restrict"* ]] || [[ "$httpcode" == "403" ]]; then
        echo -n -e "\r Hulu Japan:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" == "200" ]]; then
        echo -n -e "\r Hulu Japan:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Hulu Japan:\t\t\t\t${Font_Red}Failed (Error: ${httpcode})${Font_Suffix}\n"
}

function MediaUnlockTest_MyTVSuper() {
    local tmpresult=$(curl $curlArgs -sS -${1} --max-time 10 "https://www.mytvsuper.com/api/auth/getSession/self/" 2>&1)
    if [[ -z "$tmpresult" || "$tmpresult" == "curl"* ]]; then
        print_network_failure "MyTVSuper:\t\t\t\t" "$1" "www.mytvsuper.com"
        return
    fi
    local result=$(echo "$tmpresult" | json_query . | grep 'region' | awk '{print $2}' | tr -d ",")

    if [[ "$result" == "1" ]]; then
        echo -n -e "\r MyTVSuper:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r MyTVSuper:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    print_network_failure "MyTVSuper:\t\t\t\t" "$1" "www.mytvsuper.com"
    return

}

function MediaUnlockTest_NowTV() {
    # Now E was merged into Now TV, and webtvapi.nowe.com now answers API_NOT_FOUND.
    # Channel 630 is geo-locked and needs no login; news channels 331-333 play worldwide,
    # and nowplayer.now.com/liveplayer/play/ answers NOT_LOGIN before any geo check.
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 --user-agent "${UA_Browser}" -H "Content-Type: text/plain" -H "Origin: https://news.now.com" -H "Referer: https://news.now.com/home/live" -d "{\"contentId\":\"630\",\"contentType\":\"Channel\",\"deviceId\":\"WEB\",\"deviceType\":\"WEB\",\"callerReferenceNo\":\"W$(date +%s)000\"}" "https://webtvapi.now.com/10/7/getLiveURL" 2>&1)

    if [ -z "$tmpresult" ]; then
        print_network_failure "Now TV:\t\t\t\t" "$1" "webtvapi.now.com"
        return
    fi

    local result=$(echo "$tmpresult" | grep -o '"responseCode":"[^"]*"' | cut -f4 -d'"')

    if [[ "$result" == "SUCCESS" ]] || [[ "$result" == "NOT_LOGIN" ]] || [[ "$result" == "PRODUCT_INFORMATION_INCOMPLETE" ]]; then
        echo -n -e "\r Now TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "GEO_CHECK_FAIL" ]]; then
        echo -n -e "\r Now TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Now TV:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_ViuTV() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 -X POST -H "Content-Type: application/json" -d '{"callerReferenceNo":"20210726112323","contentId":"099","contentType":"Channel","channelno":"099","mode":"prod","deviceId":"29b3cb117a635d5b56","deviceType":"ANDROID_WEB"}' "https://api.viu.now.com/p8/3/getLiveURL" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Viu.TV:\t\t\t\t" "$1" "api.viu.now.com"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep 'responseCode' | awk '{print $2}' | cut -f2 -d'"')
    if [[ "$result" == "SUCCESS" ]]; then
        echo -n -e "\r Viu.TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "GEO_CHECK_FAIL" ]]; then
        echo -n -e "\r Viu.TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Viu.TV:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_unext() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 'https://cc.unext.jp/?zxuid=1b64984ecc23&zxemp=29854391&operationName=cosmo_getPlaylistUrl&variables=%7B%22code%22%3A%22ED00440417%22%2C%22playMode%22%3A%22caption%22%2C%22bitrateLow%22%3A192%2C%22bitrateHigh%22%3Anull%2C%22validationOnly%22%3Afalse%7D&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22a2309e22a6819ff747cf9a389dd78db35fa3c386fac1d53461061ba20fa44e34%22%7D%7D' -H "Content-Type: application/json" )
    if [ -z "$tmpresult" ]; then
        print_network_failure "U-NEXT:\t\t\t\t" "$1" "cc.unext.jp"
        return
    fi
    local result=$(echo $tmpresult | json_query . | grep 'resultStatus' | awk '{print $2}' | cut -d ',' -f1 2>&1)
    if [ -n "$result" ]; then
        if [[ "$result" == "475" ]]; then
            echo -n -e "\r U-NEXT:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
            return
        elif [[ "$result" == "200" ]]; then
            echo -n -e "\r U-NEXT:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
            return
        elif [[ "$result" == "467" ]]; then
            echo -n -e "\r U-NEXT:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
            return
        else
            echo -n -e "\r U-NEXT:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
            return
        fi
    else
        print_network_failure "U-NEXT:\t\t\t\t" "$1" "cc.unext.jp"
        return
    fi

}

function MediaUnlockTest_wowow() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sS --max-time 10 "https://mapi.wowow.co.jp/api/v1/playback/auth" -X POST -d '{"meta_id":81174}' -H "Content-Type: application/json" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "WOWOW:\t\t\t\t\t" "$1" "mapi.wowow.co.jp"
        return
    fi

    checkfailed=$(echo $tmpresult | json_query '.error.code')
    if [[ "$checkfailed" == "2055" ]]; then
        echo -n -e "\r WOWOW:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$checkfailed" == "2041" ]] || [[ "$checkfailed" == "2003" ]]; then
        echo -n -e "\r WOWOW:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r WOWOW:\t\t\t\t\t${Font_Red}Unknown (Code: $checkfailed)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_TVer() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fSsL "https://playback.api.streaks.jp/v1/projects/tver-simul-ntv/medias/ref:simul-ntv" -H 'x-streaks-api-key: ntv'  2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "TVer:\t\t\t\t\t" "$1" "playback.api.streaks.jp"
        return
    fi
    if [[ "$tmpresult" == *"project_id"* ]]; then
        echo -n -e "\r TVer:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$tmpresult" == *"403"* ]]; then
        echo -n -e "\r TVer:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r TVer:\t\t\t\t\t${Font_Red}Unknown${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_HamiVideo() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -Ss --max-time 10 "https://hamivideo.hinet.net/api/play.do?id=OTT_VOD_0000249064&freeProduct=1" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Hami Video:\t\t\t\t" "$1" "hamivideo.hinet.net"
        return
    fi

    checkfailed=$(echo $tmpresult | json_query . | grep 'code' | cut -f4 -d'"')
    if [[ "$checkfailed" == "06001-106" ]]; then
        echo -n -e "\r Hami Video:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$checkfailed" == "06001-107" ]]; then
        echo -n -e "\r Hami Video:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Hami Video:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_4GTV() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sS --max-time 10 -X POST -d 'value=D33jXJ0JVFkBqV%2BZSi1mhPltbejAbPYbDnyI9hmfqjKaQwRQdj7ZKZRAdb16%2FRUrE8vGXLFfNKBLKJv%2BfDSiD%2BZJlUa5Msps2P4IWuTrUP1%2BCnS255YfRadf%2BKLUhIPj' "https://api2.4gtv.tv//Vod/GetVodUrl3" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "4GTV.TV:\t\t\t\t" "$1" "api2.4gtv.tv"
        return
    fi

    checkfailed=$(echo $tmpresult | json_query . | grep 'Success' | awk '{print $2}' | cut -f1 -d',')
    if [[ "$checkfailed" == "false" ]]; then
        echo -n -e "\r 4GTV.TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$checkfailed" == "true" ]]; then
        echo -n -e "\r 4GTV.TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r 4GTV.TV:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_SlingTV() {
    local tmpresult=$(curl $curlArgs -${1} -sSL --max-time 10 'https://p-geo.movetv.com/geo' 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "Rakuten TV JP:\t\t\t\t" "$1" "p-geo.movetv.com"
        return
    fi

    local is_restricted=$(echo $tmpresult | json_query .ip_restricted | tr -d '"')
    local region=$(echo $tmpresult | json_query .country | tr -d '"')
    if [[ "$is_restricted" == "true" ]]; then
        echo -n -e "\r Sling TV:\t\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Sling TV:\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_PlutoTV() {
    local tmpresult=$(curl $curlArgs -${1} -sS -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://pluto.tv/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Pluto TV:\t\t\t\t" "$1" "pluto.tv"
        return
    fi

    local result=$(echo $tmpresult | grep 'thanks-for-watching')
    if [ -n "$result" ]; then
        echo -n -e "\r Pluto TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Pluto TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "Pluto TV:\t\t\t\t" "$1" "pluto.tv"
    return

}

function MediaUnlockTest_HBOMax() {
    local GetToken=$(curl $curlArgs -${1} -sS "https://default.any-any.prd.api.hbomax.com/token?realm=bolt&deviceId=afbb5daa-c327-461d-9460-d8e4b3ee4a1f"   -H 'x-device-info: beam/5.0.0 (desktop/desktop; Windows/10; afbb5daa-c327-461d-9460-d8e4b3ee4a1f/da0cdd94-5a39-42ef-aa68-54cbc1b852c3)' -H 'x-disco-client: WEB:10.15.7:dotcom-hbomax:7.7.0' -H 'x-disco-params: realm=bolt,bid=beam,features=ar' 2>&1)
    if [[ "$GetToken" == "curl"* ]]; then
        print_network_failure "HBO Max:\t\t\t\t" "$1" "default.any-any.prd.api.hbomax.com"
        return
    fi
    local Token=$(echo $GetToken | json_query .data.attributes.token | tr -d '"' )
    local APITemp=$(curl $curlArgs -${1} -sS "https://default.any-any.prd.api.hbomax.com/session-context/headwaiter/v1/bootstrap" -H 'x-disco-client: WEB:10.15.7:dotcom-hbomax:7.7.0' -H 'x-disco-params: realm=bolt,bid=beam,features=ar' -X POST -b "st=${Token}" 2>&1)
    if [[ "$APITemp" == "curl"* ]]; then
        debug_log "$APITemp"
        print_network_failure "HBO Max:\t\t\t\t" "$1" "default.any-any.prd.api.hbomax.com"
        return
    fi
    local domain=$(echo $APITemp | json_query .routing.domain | tr -d '"')
    local tenant=$(echo $APITemp | json_query .routing.tenant | tr -d '"')
    local env=$(echo $APITemp | json_query .routing.env | tr -d '"')
    local homeMarket=$(echo $APITemp | json_query .routing.homeMarket | tr -d '"')
    local tmpresult=$(curl $curlArgs -${1} -sS "https://default.$tenant-$homeMarket.$env.$domain/users/me" -H 'x-disco-client: WEB:10.15.7:dotcom-hbomax:7.7.0' -H 'x-disco-params: realm=bolt,bid=beam,features=ar' -b "st=${Token}" 2>&1)
    local result=$(echo $tmpresult | json_query .data.attributes.currentLocationTerritory | tr -d '"')
    # The homepage returns 403 without a browser User-Agent. Supported regions are its locales plus the territories they cover.
    local availableRegion=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL "https://www.hbomax.com/" 2>&1 | sed -n 's/.*id="__DOTCOM_GEO__">\([^<]*\)<\/script>.*/\1/p' | json_query -r '([.pageLocales.availableLocales[][:2]] | unique) as $c | ($c + [.brand.territory | to_entries[] | select(.key as $k | $c | index($k)) | .value[]]) | join(" ") | ascii_upcase')
    if [ -z "$availableRegion" ]; then
        echo -n -e "\r HBO Max:\t\t\t\t${Font_Red}Failed (Error: PAGE ERROR)${Font_Suffix}\n"
        return
    fi
    if [[ "$availableRegion" == *"$result"* ]] && [ -n "$result" ]; then
        echo -n -e "\r HBO Max:\t\t\t\t${Font_Green}Yes (Region: $result)${Font_Suffix}\n"
        return
    else
        echo -n -e "\r HBO Max:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    print_network_failure "HBO Max:\t\t\t\t" "$1" "default.any-any.prd.api.hbomax.com"
    return

}

function MediaUnlockTest_Channel4() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://www.channel4.com/simulcast/channels/C4" 2>&1)

    if [[ "$result" == "403" ]]; then
        echo -n -e "\r Channel 4:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$result" == "200" ]]; then
        echo -n -e "\r Channel 4:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "Channel 4:\t\t\t\t" "$1" "www.channel4.com"
    return

}

function MediaUnlockTest_ITVHUB() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://simulcast.itv.com/playlist/itvonline/ITV" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "ITV Hub:\t\t\t\t" "$1" "simulcast.itv.com"
        return
    elif [ "$result" = "404" ]; then
        echo -n -e "\r ITV Hub:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r ITV Hub:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r ITV Hub:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_iQYI_Region() {
    local tmpresult=$(curl $curlArgs -${1} -sS -I --max-time 10 "https://www.iq.com/" 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "iQyi Oversea:\t\t\t\t" "$1" "www.iq.com"
        return
    elif [ -z "$tmpresult" ]; then
        echo -n -e "\r iQyi Oversea:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
    result=$(echo "$tmpresult" | grep 'mod=' | awk '{print $2}' | cut -f2 -d'=' | cut -f1 -d';')
    region=$(echo "$tmpresult" | grep 'x-custom-client-ip:' | cut -f3 -d':' | sed 's/.$//')
    if [[ "$region" == "cn" ]]; then
            echo -n -e "\r iQyi Oversea:\t\t\t\t${Font_Yellow}Mainland (Region: $(to_upper "$region"))${Font_Suffix}\n"
            return
    fi
    if [ -n "$result" ]; then
        if [[ "$result" == "intl" ]]; then
            echo -n -e "\r iQyi Oversea:\t\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
            return
        else
            echo -n -e "\r iQyi Oversea:\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r iQyi Oversea:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
}


function MediaUnlockTest_HuluUS() {
    local tmpresult=$(curl $curlArgs -${1}  --user-agent "${UA_Browser}" -SsL 'https://auth.hulu.com/v4/web/password/authenticate' -H 'cookie: _h_csrf_id=b0b3da20eccdc796dd61d9145a095be4927a2ff56821ad4d3f91804fd6f918ea' --data-raw 'csrf=fdc1427eccde53326e27d7575c436595e28299dc420232ff26075ca06bbb28ed&password=Jam0.5cm~&scenario=web_password_login&user_email=me%40jamchoi.cc' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Hulu:\t\t\t\t\t" "$1" "auth.hulu.com"
        return
    fi

    local result=$(echo "$tmpresult" | json_query .error.name | tr -d '"')
    case "$result" in
        'LOGIN_FORBIDDEN') echo -n -e "\r Hulu:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n" ;;
        'GEO_BLOCKED') echo -n -e "\r Hulu:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n" ;;
        '' ) echo -n -e "\r Hulu:\t\t\t\t\t${Font_Red}Failed (Error: PAGE ERROR)${Font_Suffix}\n" ;;
        *) echo -n -e "\r Hulu:\t\t\t\t\t${Font_Red}Failed (Error: ${result})${Font_Suffix}\n" ;;
    esac
}

function MediaUnlockTest_encoreTVB() {
    tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 -H "Accept: application/json;pk=BCpkADawqM2Gpjj8SlY2mj4FgJJMfUpxTNtHWXOItY1PvamzxGstJbsgc-zFOHkCVcKeeOhPUd9MNHEGJoVy1By1Hrlh9rOXArC5M5MTcChJGU6maC8qhQ4Y8W-QYtvi8Nq34bUb9IOvoKBLeNF4D9Avskfe9rtMoEjj6ImXu_i4oIhYS0dx7x1AgHvtAaZFFhq3LBGtR-ZcsSqxNzVg-4PRUI9zcytQkk_YJXndNSfhVdmYmnxkgx1XXisGv1FG5GOmEK4jZ_Ih0riX5icFnHrgniADr4bA2G7TYh4OeGBrYLyFN_BDOvq3nFGrXVWrTLhaYyjxOr4rZqJPKK2ybmMsq466Ke1ZtE-wNQ" -H "Origin: https://www.encoretvb.com" "https://edge.api.brightcove.com/playback/v1/accounts/5324042807001/videos/6005570109001" 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "encoreTVB:\t\t\t\t" "$1" "www.encoretvb.com"
        return
    fi
    result=$(echo $tmpresult | json_query . | grep 'error_subcode' | cut -f4 -d'"')
    if [[ "$result" == "CLIENT_GEO" ]]; then
        echo -n -e "\r encoreTVB:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo $tmpresult | json_query . | grep 'account_id' >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -n -e "\r encoreTVB:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r encoreTVB:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    return

}

function MediaUnlockTest_Molotov() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://fapi.molotov.tv/v1/open-europe/is-france" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Molotov:\t\t\t\t" "$1" "fapi.molotov.tv"
        return
    fi

    echo $tmpresult | json_query . | grep 'false' >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -n -e "\r Molotov:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo $tmpresult | json_query . | grep 'true' >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -n -e "\r Molotov:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Molotov:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Salto() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://geo.salto.fr/v1/geoInfo/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Salto:\t\t\t\t\t" "$1" "geo.salto.fr"
        return
    fi

    local CountryCode=$(echo $tmpresult | json_query . | grep 'country_code' | cut -f4 -d'"')
    local AllowedCode="FR,GP,MQ,GF,RE,YT,PM,BL,MF,WF,PF,NC"
    echo ${AllowedCode} | grep ${CountryCode} >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo -n -e "\r Salto:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Salto:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_LineTV.TW() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://www.linetv.tw/drama/11829/eps/1" 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "LineTV.TW:\t\t\t\t" "$1" "www.linetv.tw"
        return
    fi
    if [[ "$tmpresult" != *"window.__INITIAL_STATE__"* ]]; then
        echo -n -e "\r LineTV.TW:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    # Episode details are only embedded in the page state when playback is allowed.
    if echo "$tmpresult" | grep -qE '"eps_info" *: *\[' && echo "$tmpresult" | grep -qE '"durationInMs" *: *[0-9]+'; then
        echo -n -e "\r LineTV.TW:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r LineTV.TW:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
}

function MediaUnlockTest_Viu.com() {
    local tmpresult=$(curl $curlArgs -${1} -sS -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://www.viu.com/" 2>&1)
    local banresult=$(curl $curlArgs -${1} -SsL --max-time 10 "https://d3o7oi00quuwqu.cloudfront.net" 2>&1)
    if [[ "$tmpresult" == "curl"* ]] || [[ "$banresult" == "curl"* ]]; then
        print_network_failure "Viu.com:\t\t\t\t" "$1" "www.viu.com"
        return
    fi

    result=$(echo $tmpresult | cut -f5 -d"/")
    if [ -n "$result" ]; then
        if [[ "$result" == "no-service" ]]; then
            echo -n -e "\r Viu.com:\t\t\t\t${Font_Yellow}Unsupported Region${Font_Suffix}\n"
            return
        else
            result=$(echo $result | tr 'a-z' 'A-Z')
            if [[ "$banresult" == *"block access"* ]]; then
                echo -n -e "\r Viu.com:\t\t\t\t${Font_Red}No  (Region: ${result})${Font_Suffix}\n"
                return
            else
                echo -n -e "\r Viu.com:\t\t\t\t${Font_Green}Yes (Region: ${result})${Font_Suffix}\n"
                return
            fi
        fi

    else
        echo -n -e "\r Viu.com:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_Niconico() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 -w '\n%{http_code}' "https://www.nicovideo.jp/watch/so40278367" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Niconico:\t\t\t\t" "$1" "www.nicovideo.jp"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    if [[ "$httpcode" != "200" ]] && [[ "$httpcode" != "400" ]] && [[ "$httpcode" != "403" ]] && [[ "$httpcode" != "451" ]]; then
        echo -n -e "\r Niconico:\t\t\t\t${Font_Red}Failed (Unexpected Result: ${httpcode})${Font_Suffix}\n"
        return
    fi
    local blocked=0
    # Outside Japan the watch page still returns 200 but embeds "reasonCode":"DOMESTIC_VIDEO" in its state.
    # Older pages show "同じ地域" text, possibly as escaped unicode \u540c\u3058\u5730\u57df.
    if [[ "$tmpresult" == *'DOMESTIC_VIDEO'* ]] || [[ "$tmpresult" == *"同じ地域"* ]] || [[ "$tmpresult" == *'\u540c\u3058\u5730\u57df'* ]] || [[ "$httpcode" != "200" ]]; then
        blocked=1
    fi
    local responsetype=$(echo "$tmpresult" | grep -Eo 'responseType&quot;:&quot;[A-Za-z_]+' | head -n1 | sed 's/.*&quot;//')
    if [ "$blocked" == "0" ] && [ -n "$responsetype" ] && [[ "$responsetype" != "normal" ]]; then
        echo -n -e "\r Niconico:\t\t\t\t${Font_Red}No  (${responsetype})${Font_Suffix}\n"
        return
    fi

    # Most live programs are open overseas, but official anime screenings (上映会) are Japan-only.
    # Their page state exposes userProgramWatch.isCountryRestrictionTarget and the viewer country as Niconico sees it.
    local liveid=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://live.nicovideo.jp/search?keyword=%E4%B8%8A%E6%98%A0%E4%BC%9A&providerTypes=official" 2>/dev/null | grep -Eo 'class="program-card" id="lv[0-9]+' | head -n1 | grep -Eo 'lv[0-9]+')
    if [ -z "$liveid" ]; then
        liveid=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://live.nicovideo.jp/" 2>/dev/null | grep -Eo 'nicoliveProgramId&quot;:&quot;lv[0-9]+' | head -n1 | grep -Eo 'lv[0-9]+')
    fi
    local region=""
    if [ -n "$liveid" ]; then
        local watchstate=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://live.nicovideo.jp/watch/${liveid}" 2>/dev/null | sed 's/&quot;/"/g' | grep -F '"userProgramWatch":{' | head -n1 | sed 's/.*"userProgramWatch":{//' | cut -c1-400)
        region=$(echo "$watchstate" | grep -Eo '"country":"[A-Za-z]+"' | head -n1 | cut -d'"' -f4)
        if [[ "$watchstate" == *'"isCountryRestrictionTarget":true'* ]]; then
            blocked=1
        fi
    fi
    local regiontext=""
    if [ -n "$region" ]; then
        regiontext=" (Region: $(to_upper "$region"))"
    fi
    if [ "$blocked" == "1" ]; then
        echo -n -e "\r Niconico:\t\t\t\t${Font_Red}No${regiontext}${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Niconico:\t\t\t\t${Font_Green}Yes${regiontext}${Font_Suffix}\n"
}

function MediaUnlockTest_MGStage() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSI -X GET "https://www.mgstage.com/" --write-out %{http_code} --output /dev/null 2>&1)
    if [[ "$result" == "000"* || "$result" == "curl"* ]]; then
        debug_log "$result"
        print_network_failure "MGStage:\t\t\t\t" "$1" "www.mgstage.com"
        return
    fi
    if [[ "$result" == "403" ]]; then
        echo -n -e "\r MGStage:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$result" == "200" ]]; then
        echo -n -e "\r MGStage:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r MGStage:\t\t\t\t${Font_Red}Failed ($result)${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_ParamountPlus() {
    local result=$(curl $curlArgs -${1} -Ss -o /dev/null -L --max-time 10 -w '%{http_code}_%{url_effective}\n' "https://www.paramountplus.com/" --tlsv1.3 2>&1)
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "Paramount+:\t\t\t\t" "$1" "www.paramountplus.com"
        return
    fi

    if [[ "$result" == *"intl"* ]] || [[ "$result" == "403"* ]]; then
        echo -n -e "\r Paramount+:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$result" == "200"* ]]; then
        local region=$(echo $result | cut -f4 -d '/')
        if [[ -z "$region" ]]; then
            echo -n -e "\r Paramount+:\t\t\t\t${Font_Green}Yes (Region: US)${Font_Suffix}\n"
            return
        else
            echo -n -e "\r Paramount+:\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r Paramount+:\t\t\t\t${Font_Red}Failed (Unknown Resp)${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Paramount+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    return

}

function MediaUnlockTest_KKTV() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://api.kktv.me/v3/ipcheck" 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "KKTV:\t\t\t\t\t" "$1" "api.kktv.me"
        return
    fi
    result=$(echo $tmpresult | json_query . | grep 'country' | cut -f4 -d'"')
    if [[ "$result" == "TW" ]]; then
        echo -n -e "\r KKTV:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r KKTV:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_PeacockTV() {
    local tmpresult=$(curl $curlArgs -${1} -fsL -w "%{http_code}\n%{url_effective}\n" -o /dev/null "https://www.peacocktv.com/" 2>&1)
    if [[ "$tmpresult" == "000"* ]]; then
        print_network_failure "Peacock TV:\t\t\t\t" "$1" "www.peacocktv.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'unavailable')
    if [ -n "$result" ]; then
        echo -n -e "\r Peacock TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Peacock TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_FOD() {

    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://geocontrol1.stream.ne.jp/fod-geo/check.xml?time=1624504256" 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "FOD(Fuji TV):\t\t\t\t" "$1" "geocontrol1.stream.ne.jp"
        return
    fi

    echo $tmpresult | grep 'true' >/dev/null 2>&1
    if [[ "$?" -eq 0 ]]; then
        echo -n -e "\r FOD(Fuji TV):\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r FOD(Fuji TV):\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_YouTube_Premium() {
    local tmpresult1=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} --max-time 10 -sSL -H "Accept-Language: en" -b "YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai; _gcl_au=1.1.1809531354.1646633279" "https://www.youtube.com/premium" 2>&1)
    local tmpresult2=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} --max-time 10 -sSL -H "Accept-Language: en" "https://www.youtube.com/premium" 2>&1)
    local tmpresult="$tmpresult1:$tmpresult2"

    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "YouTube Premium:\t\t\t" "$1" "www.youtube.com"
        return
    fi

    local isCN=$(echo $tmpresult | grep 'www.google.cn')
    if [ -n "$isCN" ]; then
        echo -n -e "\r YouTube Premium:\t\t\t${Font_Red}No${Font_Suffix} ${Font_Green} (Region: CN)${Font_Suffix} \n"
        return
    fi

    local region=$(echo $tmpresult | grep "countryCode" | sed 's/.*"countryCode"//' | cut -f2 -d'"')
    local isAvailable=$(echo $tmpresult | grep 'purchaseButtonOverride')
    local isAvailable2=$(echo $tmpresult | grep "Start trial")

    if [ -n "$isAvailable" ] || [ -n "$isAvailable2" ] || [ -n "$region" ]; then
        if [ -n "$region" ]; then
            echo -n -e "\r YouTube Premium:\t\t\t${Font_Green}Yes (Region: $region)${Font_Suffix}\n"
            return
        else
            echo -n -e "\r YouTube Premium:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
            return
        fi
    else
        if [ -n "$region" ]; then
            echo -n -e "\r YouTube Premium:\t\t\t${Font_Red}No  (Region: $region)${Font_Suffix} \n"
            return
        else
            echo -n -e "\r YouTube Premium:\t\t\t${Font_Red}No${Font_Suffix} \n"
            return
        fi
    fi
    echo -n -e "\r YouTube Premium:\t\t\t${Font_Red}Failed${Font_Suffix}\n"

}

# Print the city for an IATA airport code using the IATACode reference list.
# Only an exact code match counts; prints nothing when the code is unknown.
iata_location() {
    echo "${IATACode}" | awk -F'|' -v code="$(echo "$1" | tr 'a-z' 'A-Z')" '
        { gsub(/[ \t\r]/, "", $3) }
        code != "" && $3 == code { sub(/^[ \t]+/, "", $1); sub(/[ \t]+$/, "", $1); print $1; exit }'
}

function MediaUnlockTest_YouTube_CDN() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://redirector.googlevideo.com/report_mapping?di=no" 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "YouTube Region:\t\t\t" "$1" "redirector.googlevideo.com"
        return
    fi

    local cdn_node=$(echo $tmpresult | awk '{print $3}')
    if [[ "$cdn_node" == *"-"* ]]; then
        local CDN_ISP=$(echo $cdn_node | cut -f1 -d"-" | tr 'a-z' 'A-Z')
        local CDN_LOC=$(echo $cdn_node | cut -f2 -d"-" | sed 's/[^a-z]//g')
        local location=$(iata_location "$CDN_LOC")
        if [ -n "$location" ]; then
            echo -n -e "\r YouTube CDN:\t\t\t\t${Font_Yellow}$CDN_ISP in $location ($cdn_node)${Font_Suffix}\n"
        else
            echo -n -e "\r YouTube CDN:\t\t\t\t${Font_Yellow}$CDN_ISP ($cdn_node)${Font_Suffix}\n"
        fi
        return
    fi
    if [[ "$cdn_node" == *"s"* ]]; then
        local CDN_LOC=$(echo $cdn_node | cut -f2 -d"-" | cut -c1-3)
        local location=$(iata_location "$CDN_LOC")
        echo -n -e "\r YouTube CDN:\t\t\t\t${Font_Green}${location:-Unknown} ($cdn_node)${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r YouTube CDN:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    return
    
}

function MediaUnlockTest_BritBox() {
    local tmpresult=$(curl $curlArgs -${1} -sS -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://www.britbox.com/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "BritBox:\t\t\t\t" "$1" "www.britbox.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'locationnotvalidated')
    if [ -n "$result" ]; then
        local region=$(echo $tmpresult | cut -d '/' -f4)
        echo -n -e "\r BritBox:\t\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    else
        echo -n -e "\r BritBox:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "BritBox:\t\t\t\t" "$1" "www.britbox.com"
    return

}

function MediaUnlockTest_PrimeVideo_Region() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://www.primevideo.com" 2>&1)

    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "Amazon Prime Video:\t\t\t" "$1" "www.primevideo.com"
        return
    fi

    local tmpresult1=$(curl $curlArgs -${1} --user-agent "PrimeVideo/10.68 (iPad; iOS 18.3.2; Scale/2.00)" -sSL --max-time 10 "https://ab9f7h23rcdn.eu.api.amazonvideo.com/cdp/appleedge/getDataByTransform/v1/apple/detail/vod/v1.kt?itemId=amzn1.dv.gti.e6b39984-2bb6-f7d0-33e4-08ec574947f0&deviceId=6F97F9CCFA2243F1A3C44BD3C7F7908E&deviceTypeId=A3JTVZS31ZJ340&density=2x&firmware=10.6800.16104.3&format=json&enabledFeatures=denarius.location.gen4.daric.siglos.siglosPartnerBilling.contentDescriptors.contentDescriptorsV2.productPlacement.zeno.seriesSearch.tapsV2.dateTimeLocalization.multiSourcedEvents.mseEventLevelOffers.liveWatchModal.lbv.daapi.maturityRatingDecoration.seasonTrailer.cleanSlate.xbdModalV2.xbdModalVdp.playbackPinV2.exploreTab.reactions.progBadging.atfEpTimeVis.prereleaseCx.vppaConsent.episodicRelease.movieVam.movieVamCatalog&journeyIngressContext=8%7CEgRzdm9k&osLocale=en_US&timeZoneId=Etc%2FUtc&uxLocale=en_US" 2>&1)
    if [[ "$tmpresult1" = "curl"* ]]; then
        print_network_failure "Amazon Prime Video:\t\t\t" "$1" "ab9f7h23rcdn.eu.api.amazonvideo.com"
        return
    fi
    local VPNDetected=$(echo $tmpresult1 | grep "VPN")

    local result=$(echo $tmpresult | grep -oE '"currentTerritory":"[A-Z]{2}"' | head -n 1 | cut -f4 -d'"')
    if [ -n "$result" ]; then
        if [ -n "$VPNDetected" ]; then
            echo -n -e "\r Amazon Prime Video:\t\t\t${Font_Red}No  (VPN Detected;Region: $result)${Font_Suffix}\n"
            return
        else
            echo -n -e "\r Amazon Prime Video:\t\t\t${Font_Green}Yes (Region: $result)${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r Amazon Prime Video:\t\t\t${Font_Red}Unsupported${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Radiko() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://radiko.jp/area?_=1625406539531" 2>&1)

    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "Radiko:\t\t\t\t" "$1" "radiko.jp"
        return
    fi

    local checkfailed=$(echo $tmpresult | grep 'class="OUT"')
    if [ -n "$checkfailed" ]; then
        echo -n -e "\r Radiko:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    local checksuccess=$(echo $tmpresult | grep 'JAPAN')
    if [ -n "$checksuccess" ]; then
        area=$(echo $tmpresult | awk '{print $2}' | sed 's/.*>//')
        echo -n -e "\r Radiko:\t\t\t\t${Font_Green}Yes (City: $area)${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Radiko:\t\t\t\t${Font_Red}Unsupported${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_DMM() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://api-p.videomarket.jp/v3/api/play/keyauth?playKey=4c9e93baa7ca1fc0b63ccf418275afc2&deviceType=3&bitRate=0&loginFlag=0&connType=" -H "X-Authorization: 2bCf81eLJWOnHuqg6nNaPZJWfnuniPTKz9GXv5IS" 2>&1)

    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "DMM:\t\t\t\t\t" "$1" "api-p.videomarket.jp"
        return
    fi

    local checkfailed=$(echo $tmpresult | grep 'Access is denied')
    if [ -n "$checkfailed" ]; then
        echo -n -e "\r DMM:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    local checksuccess=$(echo $tmpresult | grep 'PlayKey has expired')
    if [ -n "$checksuccess" ]; then
        echo -n -e "\r DMM:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r DMM:\t\t\t\t\t${Font_Red}Unsupported${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_DMMTV() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -X POST -d '{"player_name":"dmmtv_browser","player_version":"0.0.0","content_type_detail":"VOD_SVOD","content_id":"11uvjcm4fw2wdu7drtd1epnvz","purchase_product_id":null}' "https://api.beacon.dmm.com/v1/streaming/start" 2>&1)

    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "DMM TV:\t\t\t\t" "$1" "api.beacon.dmm.com"
        return
    fi

    local checkfailed=$(echo $tmpresult | grep 'FOREIGN')
    if [ -n "$checkfailed" ]; then
        echo -n -e "\r DMM TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    local checksuccess=$(echo $tmpresult | grep 'UNAUTHORIZED')
    if [ -n "$checksuccess" ]; then
        echo -n -e "\r DMM TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r DMM TV:\t\t\t\t${Font_Red}Unsupported${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Catchplay() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://sunapi.catchplay.com/geo" -H "authorization: Basic NTQ3MzM0NDgtYTU3Yi00MjU2LWE4MTEtMzdlYzNkNjJmM2E0Ok90QzR3elJRR2hLQ01sSDc2VEoy" 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "CatchPlay+:\t\t\t\t" "$1" "sunapi.catchplay.com"
        return
    fi
    result=$(echo $tmpresult | json_query . | grep 'code' | awk '{print $2}' | cut -f2 -d'"')
    region=$(echo $tmpresult | json_query . | grep 'isoCode' | awk '{print $2}' | cut -f2 -d'"')
    if [ -n "$result" ]; then
        if [ "$result" = "0" ]; then
            echo -n -e "\r CatchPlay+:\t\t\t\t${Font_Green}Yes (Region: ${region})${Font_Suffix}\n"
            return
        elif [ "$result" = "100016" ]; then
            echo -n -e "\r CatchPlay+:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
            return
        else
            echo -n -e "\r CatchPlay+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r CatchPlay+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_HotStar() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://api.hotstar.com/o/v1/page/1557?offset=0&size=20&tao=0&tas=20" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "HotStar:\t\t\t\t" "$1" "api.hotstar.com"
        return
    elif [ "$result" = "401" ] || [ "$result" = "475" ]; then
        # The geo cookie carries the detected country even where HotStar is not served (475).
        local headers=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sI --max-time 10 "https://www.hotstar.com")
        local region=$(echo "$headers" | grep 'geo=' | sed 's/.*geo=//' | cut -f1 -d",")
        local region_note=""
        [ -n "$region" ] && region_note=" (Region: $region)"
        if echo "$headers" | grep -qi '^location:.*disneyplus\.com'; then
            echo -n -e "\r HotStar:\t\t\t\t${Font_Yellow}Served via Disney+ SEA${region_note}${Font_Suffix}\n"
            return
        fi
        # Served in these countries only. hotstar.com still answers 200 elsewhere: /us is
        # a leftover Disney Bundle landing page from the 2021 US closure.
        case "$result:$region" in
        *:IN | *:GB | *:CA | *:SG | 401:) ;;
        *)
            echo -n -e "\r HotStar:\t\t\t\t${Font_Yellow}Unsupported${region_note}${Font_Suffix}\n"
            return
            ;;
        esac
        local site_region=$(curl $curlArgs -${1} -s -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://www.hotstar.com" | sed 's@.*com/@@' | tr 'a-z' 'A-Z')
        if [ "$result" = "401" ] && [ -n "$region" ] && [ "$region" = "$site_region" ]; then
            echo -n -e "\r HotStar:\t\t\t\t${Font_Green}Yes${region_note}${Font_Suffix}\n"
        else
            echo -n -e "\r HotStar:\t\t\t\t${Font_Red}No ${region_note}${Font_Suffix}\n"
        fi
        return
    else
        echo -n -e "\r HotStar:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

# Print the SHA-256 hex digest of $1.
sha256_hex() {
    if command -v sha256sum &>/dev/null; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    else
        printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
    fi
}

# Print $1 (a non-negative integer) in base 36.
to_base36() {
    local n=$1 chars="0123456789abcdefghijklmnopqrstuvwxyz" out=""
    while [ "$n" -gt 0 ]; do
        out="${chars:$((n % 36)):1}${out}"
        n=$((n / 36))
    done
    echo "${out:-0}"
}

# Print $1 random base-36 characters.
random_base36() {
    local chars="0123456789abcdefghijklmnopqrstuvwxyz" out="" i
    for ((i = 0; i < $1; i++)); do
        out="${out}${chars:$((RANDOM % 36)):1}"
    done
    echo "$out"
}

function MediaUnlockTest_LiTV() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSi --max-time 10 -X POST "https://www.litv.tv/api/generate-device-id" -H 'content-type: application/json' -H 'origin: https://www.litv.tv' -H 'referer: https://www.litv.tv/' 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "LiTV:\t\t\t\t\t" "$1" "www.litv.tv"
        return
    fi
    local body=$(echo "$tmpresult" | sed '1,/^\r\{0,1\}$/d')
    local deviceid=$(echo "$body" | json_query -r '.deviceId // ."device-id" // empty')
    if [ -z "$deviceid" ]; then
        deviceid=$(echo "$tmpresult" | grep -i '^set-cookie: *device-id=' | head -n1 | sed 's/^[^=]*=//; s/;.*//' | tr -d '\r')
    fi
    if [ -z "$deviceid" ]; then
        echo -n -e "\r LiTV:\t\t\t\t\t${Font_Red}Failed (No Device ID)${Font_Suffix}\n"
        return
    fi

    tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -X POST "https://proxy.svc.litv.tv/cdi/v2/rpc" -H 'content-type: application/json' -H 'origin: https://www.litv.tv' -H 'referer: https://www.litv.tv/drama/watch/VOD00328856' -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"CCCService.GetProgramInformation\",\"params\":{\"version\":\"2.0\",\"project_num\":\"LTWEB02\",\"device_id\":\"${deviceid}\",\"swver\":\"LTWEB0210000WEB20190612185813\",\"content_id\":\"VOD00328856\",\"content_type\":\"drama\"}}" 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "LiTV:\t\t\t\t\t" "$1" "proxy.svc.litv.tv"
        return
    fi
    local rpcstatus=$(echo "$tmpresult" | json_query -r 'if .error != null then "no" elif (.result.data.content_id // "") != "" then "yes" else "no" end')
    if [[ "$rpcstatus" == "yes" ]]; then
        echo -n -e "\r LiTV:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$rpcstatus" == "no" ]]; then
        echo -n -e "\r LiTV:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    # The RPC answer was not JSON: fall back to the signed legacy playback API.
    tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -X POST "https://pusti.svc.litv.tv/puid" -H 'content-type: application/json' -H 'origin: https://www.litv.tv' -H 'referer: https://www.litv.tv/' -d '{"jsonrpc":"2.0","id":100,"method":"PustiService.PUID","params":{"version":"2.0","device_id":"","device_category":"LTWEB00","puid":"","aaid":"","idfa":""}}' 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "LiTV:\t\t\t\t\t" "$1" "pusti.svc.litv.tv"
        return
    fi
    local puid=$(echo "$tmpresult" | json_query -r '.result.puid // empty')
    if [ -z "$puid" ]; then
        echo -n -e "\r LiTV:\t\t\t\t\t${Font_Red}Failed (Unexpected Result)${Font_Suffix}\n"
        return
    fi
    local assetid="vod70810-000001M001_1500K"
    local mediatype="vod"
    local timestamp=$(date +%s%3N)
    if ! [[ "$timestamp" =~ ^[0-9]+$ ]]; then
        timestamp="$(date +%s)000"
    fi
    local nonce="$(random_base36 26)$(to_base36 "$timestamp")"
    local signature=$(sha256_hex "${assetid}${mediatype}${timestamp}${nonce}7f4a9c2e8b6d1f3a5e9c7b4d2f8a6e1c")
    tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -w '\n%{http_code}' -X POST "https://www.litv.tv/api/get-urls-no-auth" -H 'content-type: application/json' -H 'origin: https://www.litv.tv' -H 'referer: https://www.litv.tv/drama/watch/VOD00328856' -H "cookie: device-id=${deviceid}; PUID=${puid}" -d "{\"AssetId\":\"${assetid}\",\"MediaType\":\"${mediatype}\",\"puid\":\"${puid}\",\"timestamp\":${timestamp},\"nonce\":\"${nonce}\",\"signature\":\"${signature}\"}" 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "LiTV:\t\t\t\t\t" "$1" "www.litv.tv"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    if [[ "$httpcode" != "200" ]]; then
        echo -n -e "\r LiTV:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: ${httpcode})${Font_Suffix}\n"
        return
    fi
    if [[ "$tmpresult" == *"OutsideRegionError"* ]]; then
        echo -n -e "\r LiTV:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r LiTV:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
}

function MediaUnlockTest_FridayVideo() {
    local tmpresult=$(curl $curlArgs -${1} -sSL --max-time 10 --user-agent "${UA_Browser}" 'https://video.friday.tw/api2/streaming/get?streamingId=122581&streamingType=2&contentType=4&contentId=1&clientId=' 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "Friday Video:\t\t\t\t" "$1" "video.friday.tw"
        return
    fi
    result=$(echo $tmpresult | json_query .code | tr -d '"')
    if [[ "$result" != "null" ]]; then
        if [ "$result" = "1006" ]; then
            echo -n -e "\r Friday Video:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
            return
        elif [ "$result" = "0000" ]; then
            echo -n -e "\r Friday Video:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
            return
        else
            echo -n -e "\r Friday Video:\t\t\t\t${Font_Red}Unknown (Code: $result)${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r Friday Video:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_FuboTV() {
    local radom_num=${RANDOM:0-1}
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://api.fubo.tv/appconfig/v1/homepage?platform=web&client_version=R20230310.${radom_num}&nav=v0" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Fubo TV:\t\t\t\t" "$1" "api.fubo.tv"
        return
    fi
    local result=$(echo $tmpresult | grep 'Forbidden IP')
    if [ -n "$result" ]; then
        echo -n -e "\r Fubo TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Fubo TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Fox() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://x-live-fox-stgec.uplynk.com/ausw/slices/8d1/d8e6eec26bf544f084bad49a7fa2eac5/8d1de292bcc943a6b886d029e6c0dc87/G00000000.ts?pbs=c61e60ee63ce43359679fb9f65d21564&cloud=aws&si=0" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "FOX:\t\t\t\t\t" "$1" "x-live-fox-stgec.uplynk.com"
    elif [ "$result" = "200" ]; then
        echo -n -e "\r FOX:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r FOX:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r FOX:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Joyn() {
    local tmpauth=$(curl $curlArgs -${1} -s --max-time 10 -X POST "https://auth.joyn.de/auth/anonymous" -H "Content-Type: application/json" -d '{"client_id":"b74b9f27-a994-4c45-b7eb-5b81b1c856e7","client_name":"web","anon_device_id":"b74b9f27-a994-4c45-b7eb-5b81b1c856e7"}' 2>&1)
    if [ -z "$tmpauth" ]; then
        print_network_failure "Joyn:\t\t\t\t\t" "$1" "auth.joyn.de"
        return
    fi
    auth=$(echo $tmpauth | json_query . | grep access_token | awk '{print $2}' | cut -f2 -d'"')
    local result=$(curl $curlArgs -s "https://api.joyn.de/content/entitlement-token" -H "x-api-key: 36lp1t4wto5uu2i2nk57ywy9on1ns5yg" -H "content-type: application/json" -d '{"content_id":"daserste-de-hd","content_type":"LIVE"}' -H "authorization: Bearer $auth" 2>&1)
    if [ -n "$result" ]; then
        isBlock=$(echo $result | json_query . | grep 'code' | awk '{print $2}' | cut -f2 -d'"')
        if [[ "$isBlock" == "ENT_AssetNotAvailableInCountry" ]]; then
            echo -n -e "\r Joyn:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
            return
        else
            echo -n -e "\r Joyn:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r Joyn:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_SKY_DE() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://edge.api.brightcove.com/playback/v1/accounts/1050888051001/videos/6247131490001" -H "Accept: application/json;pk=BCpkADawqM0OXCLe4eIkpyuir8Ssf3kIQAM62a1KMa4-1_vTOWQIxoHHD4-oL-dPmlp-rLoS-WIAcaAMKuZVMR57QY4uLAmP4Ov3V416hHbqr0GNNtzVXamJ6d4-rA3Xi98W-8wtypdEyjGEZNepUCt3D7UdMthbsG-Ean3V4cafT4nZX03st5HlyK1chp51SfA-vKcAOhHZ4_Oa9TTN61tEH6YqML9PWGyKrbuN5myICcGsFzP3R2aOF8c5rPCHT2ZAiG7MoavHx8WMjhfB0QdBr2fphX24CSpUKlcjEnQJnBiA1AdLg9iyReWrAdQylX4Eyhw5OwKiCGJznfgY6BDtbUmeq1I9r9RfmhP5bfxVGjILSEFZgXbMqGOvYdrdare0aW2fTCxeHdHt0vyKOWTC6CS1lrGJF2sFPKn1T1csjVR8s4MODqCBY1PTbHY4A9aZ-2MDJUVJDkOK52hGej6aXE5b9N9_xOT2B9wbXL1B1ZB4JLjeAdBuVtaUOJ44N0aCd8Ns0o02E1APxucQqrjnEociLFNB0Bobe1nkGt3PS74IQcs-eBvWYSpolldMH6TKLu8JqgdnM4WIp3FZtTWJRADgAmvF9tVDUG9pcJoRx_CZ4im-rn-AzN3FeOQrM4rTlU3Q8YhSmyEIoxYYqsFDwbFlhsAcvqQkgaElYtuciCL5i3U8N4W9rIhPhQJzsPafmLdWxBP_FXicyek25GHFdQzCiT8nf1o860Jv2cHQ4xUNcnP-9blIkLy9JmuB2RgUXOHzWsrLGGW6hq9wLUtqwEoxcEAAcNJgmoC0k8HE-Ga-NHXng6EFWnqiOg_mZ_MDd7gmHrrKLkQV" -H "Origin: https://www.sky.de" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Sky DE:\t\t\t\t" "$1" "edge.api.brightcove.com"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep error_subcode | cut -f4 -d'"')
    if [[ "$result" == "CLIENT_GEO" ]]; then
        echo -n -e "\r Sky DE:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [ -z "$result" ] && [ -n "$tmpresult" ]; then
        echo -n -e "\r Sky DE:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Sky DE:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_ZDF() {
    # Test: request twice in a row (a single request may return 35, it becomes 0 from the second request on)
    local result=$(curl $curlArgs --user-agent "${UA_Dalvik}" -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://ssl.zdf.de/geo/de/geo.txt/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "ZDF: \t\t\t\t\t" "$1" "ssl.zdf.de"
    elif [ "$result" = "404" ]; then
        echo -n -e "\r ZDF: \t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r ZDF: \t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r ZDF: \t\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_HBOGO_ASIA() {

    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://api2.hbogoasia.com/v1/geog?lang=undefined&version=0&bundleId=www.hbogoasia.com" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "HBO GO Asia:\t\t\t\t" "$1" "api2.hbogoasia.com"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep territory)
    if [ -z "$result" ]; then
        echo -n -e "\r HBO GO Asia:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [ -n "$result" ]; then
        local CountryCode=$(echo $tmpresult | json_query . | grep country | cut -f4 -d'"')
        echo -n -e "\r HBO GO Asia:\t\t\t\t${Font_Green}Yes (Region: $CountryCode)${Font_Suffix}\n"
        return
    else
        echo -n -e "\r HBO GO Asia:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_EPIX() {
    tmpToken=$(curl $curlArgs -${1} -s -X POST --max-time 10 "https://api.epix.com/v2/sessions" -H "Content-Type: application/json" -d '{"device":{"guid":"e2add88e-2d92-4392-9724-326c2336013b","format":"console","os":"web","app_version":"1.0.2","model":"browser","manufacturer":"google"},"apikey":"53e208a9bbaee479903f43b39d7301f7","oauth":{"token":null}}' 2>&1)
    if [ -z "$tmpToken" ]; then
        print_network_failure "Epix:\t\t\t\t\t" "$1" "api.epix.com"
        return
    elif [[ "$tmpToken" == "error code"* ]]; then
        echo -n -e "\r Epix:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    EpixToken=$(echo $tmpToken | json_query . | grep 'session_token' | cut -f4 -d'"')
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 -X POST -H 'content-type: application/json' -H "x-session-token: ${EpixToken}" -d $'{"operationName":"PlayFlow","variables":{"id":"bW92aWU7MjExNDc=","supportedActions":["open_url","show_notice","start_billing","play_content","log_in","noop","confirm_provider","unlinked_provider"],"streamTypes":[{"encryptionScheme":"CBCS","packagingSystem":"DASH"},{"encryptionScheme":"CENC","packagingSystem":"DASH"},{"encryptionScheme":"NONE","packagingSystem":"HLS"},{"encryptionScheme":"SAMPLE_AES","packagingSystem":"HLS"}]},"query":"fragment ShowNotice on ShowNotice {\\n  type\\n  actions {\\n    continuationContext\\n    text\\n    __typename\\n  }\\n  description\\n  title\\n  __typename\\n}\\n\\nfragment OpenUrl on OpenUrl {\\n  type\\n  url\\n  __typename\\n}\\n\\nfragment Content on Content {\\n  title\\n  __typename\\n}\\n\\nfragment Movie on Movie {\\n  id\\n  shortName\\n  __typename\\n}\\n\\nfragment Episode on Episode {\\n  id\\n  series {\\n    shortName\\n    __typename\\n  }\\n  seasonNumber\\n  number\\n  __typename\\n}\\n\\nfragment Preroll on Preroll {\\n  id\\n  __typename\\n}\\n\\nfragment ContentUnion on ContentUnion {\\n  ...Content\\n  ...Movie\\n  ...Episode\\n  ...Preroll\\n  __typename\\n}\\n\\nfragment PlayContent on PlayContent {\\n  type\\n  continuationContext\\n  heartbeatToken\\n  currentItem {\\n    content {\\n      ...ContentUnion\\n      __typename\\n    }\\n    __typename\\n  }\\n  nextItem {\\n    content {\\n      ...ContentUnion\\n      __typename\\n    }\\n    showNotice {\\n      ...ShowNotice\\n      __typename\\n    }\\n    showNoticeAt\\n    __typename\\n  }\\n  amazonPlaybackData {\\n    pid\\n    playbackToken\\n    materialType\\n    __typename\\n  }\\n  playheadPosition\\n  vizbeeStreamInfo {\\n    customStreamInfo\\n    __typename\\n  }\\n  closedCaptions {\\n    ttml {\\n      location\\n      __typename\\n    }\\n    vtt {\\n      location\\n      __typename\\n    }\\n    xml {\\n      location\\n      __typename\\n    }\\n    __typename\\n  }\\n  hints {\\n    duration\\n    seekAllowed\\n    trackingEnabled\\n    trackingId\\n    __typename\\n  }\\n  streams(types: $streamTypes) {\\n    playlistUrl\\n    closedCaptionsEmbedded\\n    packagingSystem\\n    encryptionScheme\\n    videoQuality {\\n      height\\n      width\\n      __typename\\n    }\\n    widevine {\\n      authenticationToken\\n      licenseServerUrl\\n      __typename\\n    }\\n    playready {\\n      authenticationToken\\n      licenseServerUrl\\n      __typename\\n    }\\n    fairplay {\\n      authenticationToken\\n      certificateUrl\\n      licenseServerUrl\\n      __typename\\n    }\\n    __typename\\n  }\\n  __typename\\n}\\n\\nfragment StartBilling on StartBilling {\\n  type\\n  __typename\\n}\\n\\nfragment LogIn on LogIn {\\n  type\\n  __typename\\n}\\n\\nfragment Noop on Noop {\\n  type\\n  __typename\\n}\\n\\nfragment PreviewContent on PreviewContent {\\n  type\\n  title\\n  description\\n  stream {\\n    sources {\\n      hls {\\n        location\\n        __typename\\n      }\\n      __typename\\n    }\\n    __typename\\n  }\\n  __typename\\n}\\n\\nfragment ConfirmProvider on ConfirmProvider {\\n  type\\n  __typename\\n}\\n\\nfragment UnlinkedProvider on UnlinkedProvider {\\n  type\\n  __typename\\n}\\n\\nquery PlayFlow($id: String\u0021, $supportedActions: [PlayFlowActionEnum\u0021]\u0021, $context: String, $behavior: BehaviorEnum = DEFAULT, $streamTypes: [StreamDefinition\u0021]) {\\n  playFlow(\\n    id: $id\\n    supportedActions: $supportedActions\\n    context: $context\\n    behavior: $behavior\\n  ) {\\n    ...ShowNotice\\n    ...OpenUrl\\n    ...PlayContent\\n    ...StartBilling\\n    ...LogIn\\n    ...Noop\\n    ...PreviewContent\\n    ...ConfirmProvider\\n    ...UnlinkedProvider\\n    __typename\\n  }\\n}"}' 'https://api.epix.com/graphql'  2>&1)

    local isBlocked=$(echo $tmpresult | grep 'MGM+ is only available in the United States')
    local isOK=$(echo $tmpresult | grep StartBilling)
    if [ -n "$isBlocked" ]; then
        echo -n -e "\r MGM+:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [ -n "$isOK" ]; then
        echo -n -e "\r MGM+:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r MGM+:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_videoland() {
    local tmpresult=$(curl $curlArgs -${1} -sS --user-agent "${UA_Browser}" --max-time 10  -X POST -H 'content-type: application/json' -d '{"operationName":"IsOnboardingGeoBlocked","variables":{},"query":"query IsOnboardingGeoBlocked {\n isOnboardingGeoBlocked\n}\n"}' 'https://api.videoland.com/subscribe/videoland-account/graphql' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "videoland:\t\t\t\t" "$1" "api.videoland.com"
        return
    fi

    local result=$(echo $tmpresult | json_query .data.isOnboardingGeoBlocked)
    if [[ "$result" == "false" ]]; then
        echo -n -e "\r videoland:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r videoland:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_NPO_Start_Plus() {
    local tmptoken=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS  --max-time 10 "https://npo.nl/start/api/domain/player-token?productId=BV_101410466" 2>&1)
    if [[ "$tmptoken" == "curl"* ]]; then
        debug_log "$tmptoken"
        print_network_failure "NPO Start Plus:\t\t\t" "$1" "npo.nl"
        return
    fi
    local token=$(echo $tmptoken | json_query .token | tr -d '"')
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://prod.npoplayer.nl/stream-link" -X POST -H "Authorization:$token" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "NPO Start Plus:\t\t\t" "$1" "prod.npoplayer.nl"
        return
    fi
    local result=$(echo $tmpresult | json_query .status)
    if [[ "$result" == "451" ]]; then
        echo -n -e "\r NPO Start Plus:\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r NPO Start Plus:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_RakutenTV() {
    local tmpresult=$(curl $curlArgs -${1} -sS -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://rakuten.tv" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Rakuten TV:\t\t\t\t" "$1" "rakuten.tv"
        return
    fi
    local result=$(echo $tmpresult | grep 'waitforit')
    if [ -n "$result" ]; then
        echo -n -e "\r Rakuten TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Rakuten TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "Rakuten TV:\t\t\t\t" "$1" "rakuten.tv"
    return

}

function MediaUnlockTest_HBO_Spain() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://api-discovery.hbo.eu/v1/discover/hbo?language=null&product=hboe" -H "X-Client-Name: web" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "HBO Spain:\t\t\t\t" "$1" "api-discovery.hbo.eu"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep signupAllowed | awk '{print $2}' | cut -f1 -d",")
    if [[ "$result" == "true" ]]; then
        echo -n -e "\r HBO Spain:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "false" ]]; then
        echo -n -e "\r HBO Spain:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r HBO Spain:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_MoviStarPlus() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSI -X GET "https://contratar.movistarplus.es/" --write-out %{http_code} --output /dev/null 2>&1)
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "Movistar+:\t\t\t\t" "$1" "contratar.movistarplus.es"
        return
    fi
    if [[ "$result" == "200" ]]; then
        echo -n -e "\r Movistar+:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "403" ]]; then
        echo -n -e "\r Movistar+:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$result" == "000" ]]; then
        echo -n -e "\r Movistar+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Movistar+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_Sky_CH() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS -o /dev/null -IL -X GET --max-time 10 -w '%{url_effective}\n' "https://sky.ch/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "SKY CH:\t\t\t\t" "$1" "sky.ch"
        return
    fi
    local result=$(echo $tmpresult | grep 'out-of-country')
    if [ -n "$result" ]; then
        echo -n -e "\r SKY CH:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r SKY CH:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r SKY CH:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    return

}

function MediaUnlockTest_Starz() {
    # Based on https://github.com/oneclickvirt/UnlockTests/blob/main/us/Starz.go
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -w '\n%{http_code}' "https://www.starz.com/sapi/header/v1/starz/us/109448574b2147ccbc494b429ff5ef1b" -H "Referer: https://www.starz.com/us/en/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Starz:\t\t\t\t\t" "$1" "www.starz.com"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    local authorization=${tmpresult%$'\n'*}
    if [[ "$httpcode" == "403" ]]; then
        echo -n -e "\r Starz:\t\t\t\t\t${Font_Red}No  (Banned)${Font_Suffix}\n"
        return
    fi
    if [ -z "$authorization" ] || [[ "$authorization" == *"AccessDenied"* ]]; then
        echo -n -e "\r Starz:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: $httpcode)${Font_Suffix}\n"
        return
    fi

    local tmpresult2=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://auth.starz.com/api/v4/User/geolocation" \
        -H "AuthTokenAuthorization: $authorization" \
        -H "BestAvailableToken: true" \
        -H "Origin: https://www.starz.com" \
        -H "Referer: https://www.starz.com/" \
        -H "X-Client-Features: DeviceCount" 2>&1)
    if [[ "$tmpresult2" == "curl"* ]]; then
        print_network_failure "Starz:\t\t\t\t\t" "$1" "auth.starz.com"
        return
    fi

    local verdict=$(echo "$tmpresult2" | json_query -r 'if (.isAllowedAccess == true and .isAllowedCountry == true and .isKnownProxy == false) then "yes" else "no" end')
    if [[ "$verdict" == "yes" ]]; then
        echo -n -e "\r Starz:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [[ "$verdict" == "no" ]]; then
        echo -n -e "\r Starz:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Starz:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_CanalPlus() {
    local tmpresult=$(curl $curlArgs -${1}  --user-agent "${UA_Browser}" -sS -o /dev/null -IL -X GET --max-time 10 -w '%{url_effective}\n' "https://boutique-tunnel.canalplus.com/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Canal+:\t\t\t\t" "$1" "boutique-tunnel.canalplus.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'other-country-blocking')
    if [ -n "$result" ]; then
        echo -n -e "\r Canal+:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Canal+:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "Canal+:\t\t\t\t" "$1" "boutique-tunnel.canalplus.com"
    return

}


function MediaUnlockTest_FranceTV() {
    local tmpresult=$(curl $curlArgs -${1}  --user-agent "${UA_Browser}" -fsS -L -X GET --max-time 10  "https://geo-info.ftven.fr/ws/edgescape.json" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "France.tv:\t\t\t\t" "$1" "geo-info.ftven.fr"
        return
    fi
    local region=$(echo $tmpresult | json_query '.reponse.geo_info.country_code' | tr -d '"')
    if [[ "$region" == "FR" ]]; then
        echo -n -e "\r France.tv:\t\t\t\t${Font_Green}Yes (Region: $region)${Font_Suffix}\n"
        return
    else
        echo -n -e "\r France.tv:\t\t\t\t${Font_Red}No  (Region: $region)${Font_Suffix}\n"
        return
    fi

    print_network_failure "France.tv:\t\t\t\t" "$1" "geo-info.ftven.fr"
    return

}

function MediaUnlockTest_CBCGem() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://www.cbc.ca/g/stats/js/cbc-stats-top.js" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "CBC Gem:\t\t\t\t" "$1" "www.cbc.ca"
        return
    fi

    local result=$(echo $tmpresult | sed 's/.*country":"//' | cut -f1 -d"}" | cut -f1 -d'"')
    if [[ "$result" == "CA" ]]; then
        echo -n -e "\r CBC Gem:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r CBC Gem:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_AcornTV() {
    local tmpresult=$(curl $curlArgs -${1} -s -L --max-time 10 "https://acorn.tv/")
    local isblocked=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://acorn.tv/" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Acorn TV:\t\t\t\t" "$1" "acorn.tv"
        return
    elif [[ "$isblocked" == "403" ]]; then
        echo -n -e "\r Acorn TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    local result=$(echo $tmpresult | grep 'Not yet available in your country')
    if [ -n "$result" ]; then
        echo -n -e "\r Acorn TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Acorn TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Crave() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://capi.9c9media.com/destinations/crave_atexace/platforms/desktop/playback/contents/2189628/contentPackages/4178863/manifest.pmpd" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Crave:\t\t\t\t\t" "$1" "capi.9c9media.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'Geo Constraint Restrictions')
    if [ -n "$result" ]; then
        echo -n -e "\r Crave:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Crave:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Amediateka() {
    local tmpresult=$(curl $curlArgs -${1} -sSL -I -X GET -w "%{url_effective}" --max-time 10 --output /dev/null "https://www.amediateka.ru/" 2>&1)
    if [[ "$tmpresult" == *"curl"* ]]; then
        print_network_failure "Amediateka:\t\t\t\t" "$1" "www.amediateka.ru"
        return
    fi
    local result=$(echo $tmpresult | grep 'unavailable')
    if [ -n "$result" ]; then
        echo -n -e "\r Amediateka:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Amediateka:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_MegogoTV() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://ctx.playfamily.ru/screenapi/v4/preparepurchase/web/1?elementId=0b974dc3-d4c5-4291-9df5-81a8132f67c5&elementAlias=51459024&elementType=GAME&withUpgradeSubscriptionReturnAmount=true&forceSvod=true&includeProductsForUpsale=false&sid=mDRnXOffdh_l2sBCyUIlbA" -H "X-SCRAPI-CLIENT-TS: 1627391624026" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Megogo TV:\t\t\t\t" "$1" "ctx.playfamily.ru"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep status | awk '{print $2}' | cut -f1 -d",")
    if [[ "$result" == "0" ]]; then
        echo -n -e "\r Megogo TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "502" ]]; then
        echo -n -e "\r Megogo TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Megogo TV:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_RaiPlay() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -s --max-time 10  "https://mediapolisvod.rai.it/relinker/relinkerServlet.htm?cont=VxXwi7UcqjApssSlashbjsAghviAeeqqEEqualeeqqEEqual&output=64" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Rai Play:\t\t\t\t" "$1" "mediapolisvod.rai.it"
        return
    fi
    local result=$(echo $tmpresult | grep 'no_available')
    if [ -n "$result" ]; then
        echo -n -e "\r Rai Play:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Rai Play:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_TVBAnywhere() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://uapisfm.tvbanywhere.com.sg/geoip/check/platform/android" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "TVBAnywhere+:\t\t\t\t" "$1" "uapisfm.tvbanywhere.com.sg"
        return
    fi
    local region=$(echo $tmpresult | json_query .country | tr -d '"' )
    local result=$(echo $tmpresult | json_query .allow_in_this_country )
    if [[ "$region" == "HK" ]]; then
        echo -n -e "\r TVBAnywhere+:\t\t\t\t${Font_Yellow}Serviced by MyTvSuper (Region: ${region})${Font_Suffix}\n"
        return
    fi
    if [[ "$result" == "true" ]]; then
        echo -n -e "\r TVBAnywhere+:\t\t\t\t${Font_Green}Yes (Region: ${region})${Font_Suffix}\n"
        return
    elif [[ "$result" == "false" ]]; then
        echo -n -e "\r TVBAnywhere+:\t\t\t\t${Font_Red}No  (Region: ${region})${Font_Suffix}\n"
        return
    else
        echo -n -e "\r TVBAnywhere+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_ProjectSekai() {
    local result=$(curl $curlArgs --user-agent "User-Agent: pjsekai/48 CFNetwork/1240.0.4 Darwin/20.6.0" -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://game-version.sekai.colorfulpalette.org/1.8.1/3ed70b6a-8352-4532-b819-108837926ff5" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Project Sekai: Colorful Stage:\t\t" "$1" "game-version.sekai.colorfulpalette.org"
    elif [ "$result" = "200" ]; then
        echo -n -e "\r Project Sekai: Colorful Stage:\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Project Sekai: Colorful Stage:\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Project Sekai: Colorful Stage:\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_SHOWTIME() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://www.showtime.com/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "SHOWTIME:\t\t\t\t" "$1" "www.showtime.com"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r SHOWTIME:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r SHOWTIME:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r SHOWTIME:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_NBATV() {
    local tmpresult=$(curl $curlArgs -${1} -sSL --max-time 10 "https://www.nba.com/watch/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "NBA TV:\t\t\t\t" "$1" "www.nba.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'Service is not available in your region')
    if [ -n "$result" ]; then
        echo -n -e "\r NBA TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r NBA TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_ATTNOW() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://www.atttvnow.com/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Directv Stream:\t\t\t" "$1" "www.atttvnow.com"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r Directv Stream:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Directv Stream:\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_CineMax() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://play.maxgo.com/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "CineMax Go:\t\t\t\t" "$1" "play.maxgo.com"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r CineMax Go:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r CineMax Go:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_NetflixCDN() {
    #Detect Hijack
    local nf_web_ip=$(resolve_ip "$1" www.netflix.com)
    if [ -z "$nf_web_ip" ]; then
        print_network_failure "Netflix Preferred CDN:\t\t\t" "$1" "www.netflix.com"
        return
    else
        local nf_web_isp=$(detect_isp $nf_web_ip)
        if [[ ! "$nf_web_isp" == *"Amazon"* ]] && [[ ! "$nf_web_isp" == *"Netflix"* ]]; then
            echo -n -e "\r Netflix Preferred CDN:\t\t\t${Font_Yellow}Hijacked with [$nf_web_isp]${Font_Suffix}\n"
            return
        fi
    fi
    #Detect ISP's OCAs 
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Netflix Preferred CDN:\t\t\t" "$1" "api.fast.com"
        return
    fi
    local isp=$(echo $tmpresult | json_query .client.isp)
    local target_city=$(echo $tmpresult | json_query .targets[0].location.city | tr -d '"')
    local target_country=$(echo $tmpresult | json_query .targets[0].location.country | tr -d '"')
    local isp=$(echo $tmpresult | json_query .client.isp | tr -d '"')
    local target_url=$(echo $tmpresult | json_query .targets[0].url | tr -d '"')
    local target_fqdn=$(echo $target_url |awk -F"/" '{print $3}'| awk -F"." '{print $1}')
    if [ -n "$isp" ] && [[ "${isp}" != "null" ]] && [[ $target_url == *"isp.1.oca"*  ]]; then
        echo -n -e "\r Netflix Preferred CDN:\t\t\t${Font_Yellow}${isp}'s OCAs in ${target_city},${target_country} ($target_fqdn)${Font_Suffix}\n"
        return
    fi
    if [[ $target_url == *"isp.1.oca"* ]]; then
        echo -n -e "\r Netflix Preferred CDN:\t\t\t${Font_Yellow}ISP's OCAs in ${target_city},${target_country} ($target_fqdn)${Font_Suffix}\n"
        return
    fi
    #Detect Offical OCAs
    if [ -n "$target_city" ] && [ -n "$target_city" ]; then
        echo -n -e "\r Netflix Preferred CDN:\t\t\t${Font_Green}${target_city},${target_country} ($target_fqdn)${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Netflix Preferred CDN:\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    return

        
}

function MediaUnlockTest_HBO_Nordic() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://api-discovery.hbo.eu/v1/discover/hbo?language=null&product=hbon" -H "X-Client-Name: web" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "HBO Nordic:\t\t\t\t" "$1" "api-discovery.hbo.eu"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep signupAllowed | awk '{print $2}' | cut -f1 -d",")
    if [[ "$result" == "true" ]]; then
        echo -n -e "\r HBO Nordic:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "false" ]]; then
        echo -n -e "\r HBO Nordic:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r HBO Nordic:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_HBO_Portugal() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://api.ugw.hbogo.eu/v3.0/GeoCheck/json/PRT" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "HBO Portugal:\t\t\t\t" "$1" "api.ugw.hbogo.eu"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep allow | awk '{print $2}' | cut -f1 -d",")
    if [[ "$result" == "1" ]]; then
        echo -n -e "\r HBO Portugal:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "0" ]]; then
        echo -n -e "\r HBO Portugal:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r HBO Portugal:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_SkyGo() {
    local tmpresult=$(curl $curlArgs -${1} -sL --max-time 10 "https://skyid.sky.com/authorise/skygo?response_type=token&client_id=sky&appearance=compact&redirect_uri=skygo://auth" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Sky Go:\t\t\t\t" "$1" "skyid.sky.com"
        return
    fi

    local result=$(echo $tmpresult | grep "You don't have permission to access")
    if [ -z "$result" ]; then
        echo -n -e "\r Sky Go:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Sky Go:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_DirecTVGO() {
    local tmpresult=$(curl $curlArgs -${1} -Ss -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://www.directvgo.com/registrarse" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "DirecTV Go:\t\t\t\t" "$1" "www.directvgo.com"
        return
    fi
    local isForbidden=$(echo $tmpresult | grep 'proximamente')
    local region=$(echo $tmpresult | cut -f4 -d"/" | tr 'a-z' 'A-Z')
    if [ -n "$isForbidden" ]; then
        echo -n -e "\r DirecTV Go:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [ -z "$isForbidden" ] && [ -n "$region" ]; then
        echo -n -e "\r DirecTV Go:\t\t\t\t${Font_Green}Yes (Region: $region)${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r DirecTV Go:\t\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_DAM() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "http://cds1.clubdam.com/vhls-cds1/site/xbox/sample_1.mp4.m3u8" 2>&1)
    if [[ "$result" == "000" ]]; then
        print_network_failure "Karaoke@DAM:\t\t\t\t" "$1" "cds1.clubdam.com"
    elif [ "$result" = "200" ]; then
        echo -n -e "\r Karaoke@DAM:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Karaoke@DAM:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Karaoke@DAM:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_DiscoveryPlus() {
    local GetToken=$(curl $curlArgs -${1} -sS "https://us1-prod-direct.discoveryplus.com/token?deviceId=d1a4a5d25212400d1e6985984604d740&realm=go&shortlived=true" 2>&1)
    if [[ "$GetToken" == "curl"* ]]; then
        print_network_failure "Discovery+:\t\t\t\t" "$1" "us1-prod-direct.discoveryplus.com"
        return
    fi
    local Token=$(echo $GetToken | json_query . | grep '"token":' | cut -f4 -d'"')
    local tmpresult=$(curl $curlArgs -${1} -sS "https://us1-prod-direct.discoveryplus.com/users/me" -b "_gcl_au=1.1.858579665.1632206782; _rdt_uuid=1632206782474.6a9ad4f2-8ef7-4a49-9d60-e071bce45e88; _scid=d154b864-8b7e-4f46-90e0-8b56cff67d05; _pin_unauth=dWlkPU1qWTRNR1ZoTlRBdE1tSXdNaTAwTW1Nd0xUbGxORFV0WWpZMU0yVXdPV1l6WldFeQ; _sctr=1|1632153600000; aam_fw=aam%3D9354365%3Baam%3D9040990; aam_uuid=24382050115125439381416006538140778858; st=${Token}; gi_ls=0; _uetvid=a25161a01aa711ec92d47775379d5e4d; AMCV_BC501253513148ED0A490D45%40AdobeOrg=-1124106680%7CMCIDTS%7C18894%7CMCMID%7C24223296309793747161435877577673078228%7CMCAAMLH-1633011393%7C9%7CMCAAMB-1633011393%7CRKhpRz8krg2tLO6pguXWp5olkAcUniQYPHaMWWgdJ3xzPWQmdj0y%7CMCOPTOUT-1632413793s%7CNONE%7CvVersion%7C5.2.0; ass=19ef15da-95d6-4b1d-8fa2-e9e099c9cc38.1632408400.1632406594" 2>&1)
    local result=$(echo $tmpresult | json_query . | grep currentLocationTerritory | cut -f4 -d'"')
    if [[ "$result" == "us" ]]; then
        echo -n -e "\r Discovery+:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Discovery+:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Discovery+:\t\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_ESPNPlus() {
    local espncookie=$(echo "$Media_Cookie" | sed -n '11p')
    local TokenContent=$(curl -${1} --user-agent "${UA_Browser}" -s --max-time 10 -X POST "https://espn.api.edge.bamgrid.com/token" -H "authorization: Bearer ZXNwbiZicm93c2VyJjEuMC4w.ptUt7QxsteaRruuPmGZFaJByOoqKvDP2a5YkInHrc7c" -d "$espncookie" 2>&1)
    local isBanned=$(echo $TokenContent | json_query . | grep 'forbidden-location')
    local is403=$(echo $TokenContent | grep '403 ERROR')

    if [ -n "$isBanned" ] || [ -n "$is403" ]; then
        echo -n -e "\r ESPN+:${Font_SkyBlue}[Sponsored by Jam]${Font_Suffix}\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    local fakecontent=$(echo "$Media_Cookie" | sed -n '10p')
    local refreshToken=$(echo $TokenContent | json_query . | grep 'refresh_token' | awk '{print $2}' | cut -f2 -d'"')
    local espncontent=$(echo $fakecontent | sed "s/ILOVESTAR/${refreshToken}/g")
    local tmpresult=$(curl -${1} --user-agent "${UA_Browser}" -X POST -sSL --max-time 10 "https://espn.api.edge.bamgrid.com/graph/v1/device/graphql" -H "authorization: ZXNwbiZicm93c2VyJjEuMC4w.ptUt7QxsteaRruuPmGZFaJByOoqKvDP2a5YkInHrc7c" -d "$espncontent" 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "ESPN+:${Font_SkyBlue}[Sponsored by Jam]${Font_Suffix}\t\t" "$1" "espn.api.edge.bamgrid.com"
        return
    fi
    local region=$(echo $tmpresult | json_query . | grep 'countryCode' | cut -f4 -d'"')
    local inSupportedLocation=$(echo $tmpresult | json_query . | grep 'inSupportedLocation' | awk '{print $2}' | cut -f1 -d',')

    if [[ "$region" == "US" ]] && [[ "$inSupportedLocation" == "true" ]]; then
        echo -n -e "\r ESPN+:${Font_SkyBlue}[Sponsored by Jam]${Font_Suffix}\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r ESPN+:${Font_SkyBlue}[Sponsored by Jam]${Font_Suffix}\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Stan() {
    local tmpresult=$(curl $curlArgs -${1} -X POST -sS --max-time 10 "https://api.stan.com.au/login/v1/sessions/web/account" 2>&1)
    if [[ -z "$tmpresult" || "$tmpresult" == "curl"* ]]; then
        print_network_failure "Stan:\t\t\t\t\t" "$1" "api.stan.com.au"
        return
    fi

    local result=$(echo $tmpresult | grep VPNDetected)
    if [ -z "$result" ]; then
        echo -n -e "\r Stan:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Stan:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_Binge() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://auth.streamotion.com.au" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Binge:\t\t\t\t\t" "$1" "auth.streamotion.com.au"
        return
    elif [ "$result" = "200" ] || [ "$result" = "302" ]; then
        echo -n -e "\r Binge:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Binge:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Binge:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Docplay() {
    local tmpresult=$(curl $curlArgs -${1} -Ss -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://www.docplay.com/subscribe" 2>&1)
    if [[ "$tmpresult" == *"curl: ("* ]]; then
        print_network_failure "Docplay:\t\t\t\t" "$1" "www.docplay.com"
        isKayoSportsOK=2
        return
    fi
    local result=$(echo "$tmpresult" | grep 'geoblocked')
    if [ -n "$result" ]; then
        echo -n -e "\r Docplay:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        isKayoSportsOK=0
        return
    else
        echo -n -e "\r Docplay:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        isKayoSportsOK=1
        return
    fi

    print_network_failure "Docplay:\t\t\t\t" "$1" "www.docplay.com"
    isKayoSportsOK=2
    return

}

function MediaUnlockTest_OptusSports() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://sport.optus.com.au/api/userauth/validate/web/username/restriction.check@gmail.com" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Optus Sports:\t\t\t\t" "$1" "sport.optus.com.au"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r Optus Sports:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Optus Sports:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Optus Sports:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_KayoSports() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://auth.streamotion.com.au" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Kayo Sports:\t\t\t\t" "$1" "auth.streamotion.com.au"
        return
    elif [ "$result" = "200" ] || [ "$result" = "302" ]; then
        echo -n -e "\r Kayo Sports:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Kayo Sports:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Kayo Sports:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_NeonTV() {
    local NeonHeader=$(echo "$Media_Cookie" | sed -n '12p')
    local NeonContent=$(echo "$Media_Cookie" | sed -n '13p')
    local tmpresult=$(curl $curlArgs -${1} -sS -X POST "https://api.neontv.co.nz/api/client/gql?" -H "content-type: application/json" -H "$NeonHeader" -d "$NeonContent" 2>&1)
    if [[ -z "$tmpresult" || "$tmpresult" == "curl"* ]]; then
        print_network_failure "Neon TV:\t\t\t\t" "$1" "api.neontv.co.nz"
        return
    fi

    local result=$(echo $tmpresult | grep 'RESTRICTED_GEOLOCATION')
    if [ -z "$result" ]; then
        echo -n -e "\r Neon TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Neon TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_SkyGONZ() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSL --max-time 10  --output /dev/null -w %{http_code} "https://linear-s.stream.skyone.co.nz/sky-sport-1.mpd" 2>&1)
    if [[ "$result" == "000"* || "$result" == "curl"* ]]; then
        print_network_failure "SkyGo NZ:\t\t\t\t" "$1" "linear-s.stream.skyone.co.nz"
        return
    fi
    if [[ "$result" == "200" ]]; then
        echo -n -e "\r SkyGo NZ:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r SkyGo NZ:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r SkyGo NZ:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_ThreeNow() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://bravo-livestream.fullscreen.nz/index.m3u8" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "ThreeNow:\t\t\t\t" "$1" "bravo-livestream.fullscreen.nz"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r ThreeNow:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r ThreeNow:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r ThreeNow:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_MaoriTV() {
    local tmpresult=$(curl $curlArgs -${1} -s --max-time 10 "https://edge.api.brightcove.com/playback/v1/accounts/1614493167001/videos/6275380737001" -H "Accept: application/json;pk=BCpkADawqM2E9yW4lLgKIEIV5majz5djzZCIqJiYMkP5yYaYdF6AQYq4isPId1ZLtQdGnK1ErLYG0-r1N-3DzAEdbfvw9SFdDWz_i09pLp8Njx1ybslyIXid-X_Dx31b7-PLdQhJCws-vk6Y" -H "Origin: https://www.maoritelevision.com" 2>&1)
    if [ -z "$tmpresult" ]; then
        print_network_failure "Maori TV:\t\t\t\t" "$1" "edge.api.brightcove.com"
        return
    fi

    local result=$(echo $tmpresult | json_query . | grep error_subcode | cut -f4 -d'"')
    if [[ "$result" == "CLIENT_GEO" ]]; then
        echo -n -e "\r Maori TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [ -z "$result" ] && [ -n "$tmpresult" ]; then
        echo -n -e "\r Maori TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Maori TV:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_SBSonDemand() {

    local tmpresult=$(curl $curlArgs -${1} -sS "https://www.sbs.com.au/api/v3/network?context=odwebsite" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "SBS on Demand:\t\t\t\t" "$1" "www.sbs.com.au"
        return
    fi
    local result=$(echo $tmpresult | json_query . | grep country_code | cut -f4 -d'"')
    if [[ "$result" == "AU" ]]; then
        echo -n -e "\r SBS on Demand:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r SBS on Demand:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r SBS on Demand:\t\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_ABCiView() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://api.iview.abc.net.au/v2/show/abc-kids-live-stream/video/LS1604H001S00?embed=highlightVideo,selectedSeries" 2>&1)
    if [[ -z "$tmpresult" || "$tmpresult" == "curl"* ]]; then
        print_network_failure "ABC iView:\t\t\t\t" "$1" "api.iview.abc.net.au"
        return
    fi

    local result=$(echo $tmpresult | grep 'unavailable outside Australia')
    if [ -z "$result" ]; then
        echo -n -e "\r ABC iView:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r ABC iView:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_Channel9() {
    local tmpresult=$(curl $curlArgs -${1} -Ss -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://login.nine.com.au" 2>&1)
    if [[ "$tmpresult" == *"curl: ("* ]]; then
        print_network_failure "Channel 9:\t\t\t\t" "$1" "login.nine.com.au"
        return
    fi
    local result=$(echo "$tmpresult" | grep 'geoblock')
    if [ -n "$result" ]; then
        echo -n -e "\r Channel 9:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Channel 9:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "Channel 9:\t\t\t\t" "$1" "login.nine.com.au"
    return

}

function MediaUnlockTest_Telasa() {
    local tmpresult=$(curl $curlArgs -${1} -sS "https://api-videopass-anon.kddi-video.com/v1/playback/system_status" -H "X-Device-ID: d36f8e6b-e344-4f5e-9a55-90aeb3403799" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Telasa:\t\t\t\t" "$1" "api-videopass-anon.kddi-video.com"
        return
    fi
    local isForbidden=$(echo $tmpresult | grep IPLocationNotAllowed)
    local isAllowed=$(echo $tmpresult | json_query . | grep '"type"' | cut -f4 -d'"')
    if [ -n "$isForbidden" ]; then
        echo -n -e "\r Telasa:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [ -z "$isForbidden" ] && [[ "$isAllowed" == "OK" ]]; then
        echo -n -e "\r Telasa:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Telasa:\t\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_SetantaSports() {
    local tmpresult=$(curl $curlArgs -${1} -sS "https://dce-frontoffice.imggaming.com/api/v2/consent-prompt" -H "Realm: dce.adjara" -H "x-api-key: 857a1e5d-e35e-4fdf-805b-a87b6f8364bf" 2>&1)
    local tmpresult1=$(curl $curlArgs -${1} -sS "https://dce-frontoffice.imggaming.com/api/v3/i18n/country-codes" -H "Realm: dce.adjara" -H "x-api-key: 857a1e5d-e35e-4fdf-805b-a87b6f8364bf" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Setanta Sports:\t\t\t" "$1" "dce-frontoffice.imggaming.com"
        return
    fi
    local result=$(echo $tmpresult | json_query . | grep outsideAllowedTerritories | awk '{print $2}' | cut -f1 -d",")
    local region=$(echo $tmpresult1 | json_query . | grep callerCountryCode | awk '{print $2}' | cut -f2 -d'"')
    if [[ "$result" == "true" ]]; then
        echo -n -e "\r Setanta Sports:\t\t\t${Font_Red}No  (Region: ${region})${Font_Suffix}\n"
        return
    elif [[ "$result" == "false" ]]; then
        echo -n -e "\r Setanta Sports:\t\t\t${Font_Green}Yes (Region: ${region})${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Setanta Sports:\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_MolaTV() {
    local tmpresult=$(curl $curlArgs -${1} -sS "https://mola.tv/api/v2/videos/geoguard/check/vd30491025" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Mola TV:\t\t\t\t" "$1" "mola.tv"
        return
    fi
    local result=$(echo $tmpresult | json_query . | grep isAllowed | awk '{print $2}')
    if [[ "$result" == "true" ]]; then
        echo -n -e "\r Mola TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "false" ]]; then
        echo -n -e "\r Mola TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Mola TV:\t\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_BeinConnect() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://proxies.bein-mena-production.eu-west-2.tuc.red/proxy/availableOffers" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Bein Sports Connect:\t\t\t" "$1" "proxies.bein-mena-production.eu-west-2.tuc.red"
        return
    elif [ "$result" = "500" ]; then
        echo -n -e "\r Bein Sports Connect:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "451" ]; then
        echo -n -e "\r Bein Sports Connect:\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Bein Sports Connect:\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_EurosportRO() {
    local tmpresult=$(curl $curlArgs -${1} -sS "https://eu3-prod-direct.eurosport.ro/playback/v2/videoPlaybackInfo/sourceSystemId/eurosport-vid1560178?usePreAuth=true" -H 'Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJVU0VSSUQ6ZXVyb3Nwb3J0OjlkMWU3MmYyLTdkYjItNDE2Yy1iNmIyLTAwZjQyMWRiN2M4NiIsImp0aSI6InRva2VuLTc0MDU0ZDE3LWFhNWUtNGI0ZS04MDM4LTM3NTE4YjBiMzE4OCIsImFub255bW91cyI6dHJ1ZSwiaWF0IjoxNjM0NjM0MzY0fQ.T7X_JOyvAr3-spU_6wh07re4W-fmbCxZdGaUSZiu1mw' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Eurosport RO:\t\t\t\t" "$1" "eu3-prod-direct.eurosport.ro"
        return
    fi
    local result=$(echo $tmpresult | json_query . | grep access.denied.geoblocked)
    if [ -n "$result" ]; then
        echo -n -e "\r Eurosport RO:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Eurosport RO:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Eurosport RO:\t\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_DiscoveryPlusUK() {
    local GetToken=$(curl $curlArgs -${1} -sS "https://disco-api.discoveryplus.co.uk/token?realm=questuk&deviceId=61ee588b07c4df08c02861ecc1366a592c4ad02d08e8228ecfee67501d98bf47&shortlived=true" 2>&1)
    if [[ "$GetToken" == "curl"* ]]; then
        print_network_failure "Discovery+ UK:\t\t\t\t" "$1" "disco-api.discoveryplus.co.uk"
        return
    fi
    local Token=$(echo $GetToken | json_query . | grep '"token":' | cut -f4 -d'"')
    local tmpresult=$(curl $curlArgs -${1} -sS "https://disco-api.discoveryplus.co.uk/users/me" -b "st=${Token}" 2>&1)
    local result=$(echo $tmpresult | json_query . | grep currentLocationTerritory | cut -f4 -d'"')
    if [[ "$result" == "gb" ]]; then
        echo -n -e "\r Discovery+ UK:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Discovery+ UK:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Discovery+ UK:\t\t\t\t${Font_Red}Failed ${Font_Suffix}\n"
    return

}

function MediaUnlockTest_Channel5() {
    local Timestamp=$(date +%s)
    local tmpresult=$(curl $curlArgs -${1} -sL --max-time 10 "https://cassie.channel5.com/api/v2/live_media/my5desktopng/C5.json?timestamp=${Timestamp}&auth=0_rZDiY0hp_TNcDyk2uD-Kl40HqDbXs7hOawxyqPnbI" 2>&1)
    local result=$(echo $tmpresult | json_query . | grep code | cut -f4 -d'"')
    if [ -z "$tmpresult" ]; then
        print_network_failure "Channel 5:\t\t\t\t" "$1" "cassie.channel5.com"
    elif [[ "$result" == "4003" ]]; then
        echo -n -e "\r Channel 5:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ -n "$result" ] && [[ "$result" != "4003" ]]; then
        echo -n -e "\r Channel 5:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Channel 5:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_MyVideo() {
    local tmpresult=$(curl $curlArgs -${1} -SsL -o /dev/null --max-time 10 -w '%{url_effective}\n' "https://www.myvideo.net.tw/login.do" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "MyVideo:\t\t\t\t" "$1" "www.myvideo.net.tw"
        return
    fi

    local result=$(echo $tmpresult | grep 'serviceAreaBlock')
    if [ -n "$result" ]; then
        echo -n -e "\r MyVideo:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r MyVideo:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "MyVideo:\t\t\t\t" "$1" "www.myvideo.net.tw"
    return

}

function MediaUnlockTest_7plus() {
    local result1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://7plus-sevennetwork.akamaized.net/media/v1/dash/live/cenc/5303576322001/68dca38b-85d7-4dae-b1c5-c88acc58d51c/f4ea4711-514e-4cad-824f-e0c87db0a614/225ec0a0-ef18-4b7c-8fd6-8dcdd16cf03a/1x/segment0.m4f?akamai_token=exp=1672500385~acl=/media/v1/dash/live/cenc/5303576322001/68dca38b-85d7-4dae-b1c5-c88acc58d51c/f4ea4711-514e-4cad-824f-e0c87db0a614/*~hmac=800e1e1d1943addf12b71339277c637c7211582fe12d148e486ae40d6549dbde" 2>&1)
    if [[ "$result1" == "000" ]]; then
        print_network_failure "7plus:\t\t\t\t\t" "$1" "7plus-sevennetwork.akamaized.net"
        return
    fi
    if [[ "$result1" == "200" ]]; then
        echo -n -e "\r 7plus:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r 7plus:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_Channel10() {
    local tmpresult=$(curl $curlArgs -${1} -sLS --max-time 10 "https://e410fasadvz.global.ssl.fastly.net/geo" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Channel 10:\t\t\t\t" "$1" "e410fasadvz.global.ssl.fastly.net"
        return
    fi
    local result=$(echo $tmpresult | json_query . | grep 'allow' | awk '{print $2}' | cut -f1 -d",")
    if [[ "$result" == "false" ]]; then
        echo -n -e "\r Channel 10:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$result" == "true" ]]; then
        echo -n -e "\r Channel 10:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "Channel 10:\t\t\t\t" "$1" "e410fasadvz.global.ssl.fastly.net"
    return

}

function MediaUnlockTest_Spotify() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 https://www.spotify.com/tw/signup 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Spotify Region:\t\t\t" "$1" "www.spotify.com"
        return
    fi

    local country=$(echo $tmpresult | grep -Eo 'geoCountry.*","geoCountryMarket"')

    if [ -n "$country" ]; then
        echo -n -e "\r Spotify Region:\t\t\t${Font_Green}$(trim_chars "$country" 13 20)${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Spotify Region:\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_VideoMarket() {
    local TokenSrc=$(curl $curlArgs  --user-agent "${UA_Browser}" -${1} -Ss --max-time 10 "https://www.videomarket.jp/player/17588S/A17588S001999H01"  2>&1)
    if [[ "$TokenSrc" == "curl"* ]]; then
        print_network_failure "VideoMarket:\t\t\t\t" "$1" "www.videomarket.jp"
        return
    fi
    local Token=$(echo $TokenSrc| grep -Eo 'notLoggedInTokenPc:.*notLoggedInTokenSpAndroid')
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --compressed --max-time 10 "https://www.videomarket.jp/graphql" -X POST -H "Content-Type: application/json" -d '{"operationName":"readStatus","variables":{},"query":"query readStatus {\n  readStatus {\n    isRead\n    __typename\n  }\n}\n"}' -H "Authorization:Bearer $(trim_chars "$Token" 20 27)"   2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "VideoMarket:\t\t\t\t" "$1" "www.videomarket.jp"
        return
    fi
    local result=$(echo $tmpresult | grep OverseasAccess)
    if [ -n "$result" ]; then
        echo -n -e "\r VideoMarket:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r VideoMarket:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_J:COM_ON_DEMAND() {
	local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' -H 'accept-language: ja,en-US;q=0.9' -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' -H 'sec-fetch-site: same-site' -H 'sec-fetch-user: ?1' -H 'upgrade-insecure-requests: 1' -H 'referer: https://id.zaq.ne.jp/' "https://auth.id2.zaq.ne.jp/api/connect/v1/authz?scope=openid+profile+http%3A%2F%2Fjcom.co.jp%2Fconnect%2Fprofile%2Fstandard_new+http%3A%2F%2Fjcom.co.jp%2Fconnect%2Fprofile%2Fstandard_plus&response_type=code+id_token&client_id=pid_front&redirect_uri=https%3A%2F%2Fid.zaq.ne.jp%2Fid%2Fscript%2Fconnect%2Fauthz_req%2FgetFlagParam.html%3Fclient_url%3Dhttps%3A%2F%2Fid.zaq.ne.jp%2Fpidefront%2Findex.php&code_challenge_method=&code_challenge=&prompt=&state=&nonce=JsY2r6aYPlOovoqAHpbCafntXuxjhk78&login_hint=&acr_values=" 2>&1)
	if [ "$result" = "000" ]; then
        print_network_failure "J:com On Demand:\t\t\t" "$1" "auth.id2.zaq.ne.jp"
    elif [ "$result" = "200" ]; then
        echo -n -e "\r J:com On Demand:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r J:com On Demand:\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r J:com On Demand:\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_music.jp() {
	local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://overseaauth.music-book.jp/globalIpcheck.js" 2>&1)
	if [[ "$result" == "curl"* ]]; then
		print_network_failure "music.jp:\t\t\t\t" "$1" "overseaauth.music-book.jp"
		return
	fi
	if [ -n "$result" ]; then
        echo -n -e "\r music.jp:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    else
        echo -n -e "\r music.jp:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Instagram.Music() {
    local tmpresult=$(curl -sS --user-agent "${UA_Browser}" $curlArgs -${1}  'https://www.instagram.com/graphql/query'  -d 'av=0&__d=www&__user=0&__a=1&__req=3&__hs=19876.HYP%3Ainstagram_web_pkg.2.1..0.0&dpr=1&__ccg=UNKNOWN&__rev=1013915830&__s=e0krj4%3Ay7ob1k%3Arsdf9x&__hsi=7375722728458088454&__dyn=7xeUjG1mxu1syUbFp40NonwgU7SbzEdF8aUco2qwJw5ux609vCwjE1xoswaq0yE7i0n24oaEd86a3a1YwBgao6C0Mo2iyo7u3i4U2zxe2GewGwso88cobEaU2eUlwhEe87q7U1bobpEbUGdwtU662O0z8c86-3u2WE5B0bK1Iwqo5q1IQp1yUoxe4UrAwCAxW6Uf9EO6VU8U&__csr=gpgJOllNq9nP9ROd9bqTh-GEzh_jppaAGmAyGprFoBkVqmh2QHF28y-GBrgHV9aByaQ8XiyUCl7GX-bl12UHx2gxp8GUSuaBVAGCXK48zHKHUG2mi669G8KcjAgCEW8yax911u6V5yE01mJPw2mpU4yu1I8030e56OmawtxxkaDwkEGu0yQ0eYwdfw6NyGiG2Cae2S0Z80gvwsU2ACkE020ww3UU&__comet_req=7&lsd=AVpOeIV9Tzw&jazoest=2984&__spin_r=1013915830&__spin_b=trunk&__spin_t=1717294270&fb_api_caller_class=RelayModern&fb_api_req_friendly_name=PolarisPostActionLoadPostQueryQuery&variables=%7B%22shortcode%22%3A%22C2YEAdOh9AB%22%2C%22fetch_comment_count%22%3A0%2C%22parent_comment_count%22%3A0%2C%22child_comment_count%22%3A0%2C%22fetch_like_count%22%3A0%2C%22fetch_tagged_user_count%22%3Anull%2C%22fetch_preview_comment_count%22%3A0%2C%22has_threaded_comments%22%3Atrue%2C%22hoisted_comment_id%22%3Anull%2C%22hoisted_reply_id%22%3Anull%7D&server_timestamps=true&doc_id=25531498899829322' 2>&1 )
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Instagram Licensed Music:\t\t" "$1" "www.instagram.com"
        return
    fi
    local result=$(echo $tmpresult | json_query .data.xdt_shortcode_media.clips_music_attribution_info.should_mute_audio)
    if [[ "$result" == "false" ]]; then
        echo -n -e "\r Instagram Licensed Music:\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [[ "$result" == "true" ]]; then
        echo -n -e "\r Instagram Licensed Music:\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Instagram Licensed Music:\t\t${Font_Red}No  (Failed)${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_Popcornflix(){
    # Relaunched on Future Today's platform: the app config reports the detected country,
    # and the library is licensed for the US only.
    local api="https://popcornflix.com/home/new/v444/api"
    local query="appId=9&siteId=1518&auth-token=1217575&deviceId=f4565b54-f556-5ce7-b656-5e7af756600d&apiEnv=production"
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -H "Referer: https://popcornflix.com/" "${api}/getSecurityToken.php?&${query}" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Popcornflix:\t\t\t\t" "$1" "popcornflix.com"
        return
    fi
    local token=$(echo "$tmpresult" | json_query -r '.securityToken // empty')
    if [ -z "$token" ]; then
        echo -n -e "\r Popcornflix:\t\t\t\t${Font_Red}Failed (Error: PAGE ERROR)${Font_Suffix}\n"
        return
    fi
    local config=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -H "Referer: https://popcornflix.com/" -H "X-Requested-With: XMLHttpRequest" -H "token: ${token}" "${api}/index.php?parent=home&${query}" 2>&1)
    if [[ "$config" == "curl"* ]]; then
        print_network_failure "Popcornflix:\t\t\t\t" "$1" "popcornflix.com"
        return
    fi
    local region=$(echo "$config" | json_query -r '.countryCode // empty')
    if [[ "$region" == "US" ]]; then
        echo -n -e "\r Popcornflix:\t\t\t\t${Font_Green}Yes (Region: US)${Font_Suffix}\n"
    elif [ -n "$region" ]; then
        echo -n -e "\r Popcornflix:\t\t\t\t${Font_Red}No  (Region: ${region})${Font_Suffix}\n"
    else
        echo -n -e "\r Popcornflix:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_TubiTV(){
    local tmpresult=$(curl $curlArgs -${1} -sSL --user-agent "${UA_Browser}" -w "%{url_effective}\n" -o /dev/null  --max-time 10 "https://tubitv.com" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Tubi TV:\t\t\t\t" "$1" "tubitv.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'gdpr.tubi.tv')
    if [ -n "$result" ]; then
        echo -n -e "\r Tubi TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Tubi TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Philo(){
    local tmpresult=$(curl $curlArgs -${1} -fsSL --user-agent "${UA_Browser}" --max-time 10 "https://content-us-east-2-fastly-b.www.philo.com/geo" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Philo:\t\t\t\t\t" "$1" "content-us-east-2-fastly-b.www.philo.com"
        return
    fi
    local result=$(echo $tmpresult | json_query . | grep '"status":' | cut -f1 -d',' | awk '{print $2}' | sed 's/"//g')
    if [[ "$result" == 'FAIL' ]]; then
        echo -n -e "\r Philo:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    elif [[ "$result" == 'SUCCESS' ]]; then
        echo -n -e "\r Philo:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    else
        echo -n -e "\r Philo:\t\t\t\t\t${Font_Green}Failed${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_FXNOW(){
    local tmpresult=$(curl $curlArgs -${1} -fsSL --user-agent "${UA_Browser}" --max-time 10 "https://fxnow.fxnetworks.com/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "FXNOW:\t\t\t\t\t" "$1" "fxnow.fxnetworks.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'is not accessible')
    if [ -n "$result" ]; then
        echo -n -e "\r FXNOW:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r FXNOW:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Crunchyroll(){
    local tmpresult=$(curl $curlArgs -${1} -fsSL --user-agent "${UA_Browser}" --max-time 10 "https://c.evidon.com/geo/country.js" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Crunchyroll:\t\t\t\t" "$1" "c.evidon.com"
        return
    fi
    local result=$(echo $tmpresult | grep "'code':'us'")
    if [ -z "$result" ]; then
        echo -n -e "\r Crunchyroll:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Crunchyroll:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}


function MediaUnlockTest_CWTV(){
    local result=$(curl $curlArgs -${1} -fsL --user-agent "${UA_Browser}" --write-out %{http_code} --output /dev/null --max-time 10 --retry 3 "https://www.cwtv.com/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "CW TV:\t\t\t\t\t" "$1" "www.cwtv.com"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r CW TV:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    elif [ "$result" = "200" ]; then
        echo -n -e "\r CW TV:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    else
        echo -n -e "\r CW TV:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Shudder(){
    local tmpresult=$(curl $curlArgs -${1} -sS --user-agent "${UA_Browser}" --max-time 10 "https://www.shudder.com/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Shudder:\t\t\t\t" "$1" "www.shudder.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'not available')
    if [ -n "$result" ]; then
        echo -n -e "\r Shudder:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Shudder:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_TLCGO(){
    onetrustresult=$(curl $curlArgs -${1} -sS --user-agent "${UA_Browser}" --max-time 10 "https://geolocation.onetrust.com/cookieconsentpub/v1/geo/location/dnsfeed" 2>&1)
    if [[ "$onetrustresult" == "curl"* ]]; then
        print_network_failure "TLC GO:\t\t\t\t" "$1" "geolocation.onetrust.com"
        return
    elif [ -z "$onetrustresult" ]; then
        echo -n -e "\r TLC GO:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
    local result=$(echo $onetrustresult | grep '"country":"US"')
    if [ -z "$result" ]; then
        echo -n -e "\r TLC GO:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r TLC GO:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Wavve() {
    local result1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://apis.wavve.com/fz/streaming?device=pc&partner=pooq&apikey=E5F3E0D30947AA5440556471321BB6D9&credential=none&service=wavve&pooqzone=none&region=kor&drm=pr&targetage=all&contentid=MV_C3001_C300000012559&contenttype=movie&hdr=sdr&videocodec=avc&audiocodec=ac3&issurround=n&format=normal&withinsubtitle=n&action=dash&protocol=dash&quality=auto&deviceModelId=Windows%2010&guid=1a8e9c88-6a3b-11ed-8584-eed06ef80652&lastplayid=none&authtype=cookie&isabr=y&ishevc=n" 2>&1)
    if [[ "$result1" == "000" ]]; then
        print_network_failure "Wavve:\t\t\t\t\t" "$1" "apis.wavve.com"
        return
    fi
    if [[ "$result1" == "200" ]]; then
        echo -n -e "\r Wavve:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    else
        echo -n -e "\r Wavve:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Tving() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fSsL --max-time 10 "https://api.tving.com/v2a/media/stream/info?apiKey=1e7952d0917d6aab1f0293a063697610&mediaCode=RV60891248" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Tving:\t\t\t\t\t" "$1" "api.tving.com"
        return
    fi
    local result1=$(echo $tmpresult | json_query . | grep 'play')
    if [ -z "$result1" ]; then
        echo -n -e "\r Tving:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Tving:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_CoupangPlay() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fSsI --max-time 10 "https://www.coupangplay.com/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Coupang Play:\t\t\t\t" "$1" "www.coupangplay.com"
        return
    fi
    local result1=$(echo "$tmpresult" | grep -i 'Location' | awk '{print $2}' )
    if [[ "$result1" == *"/not-available"* ]]; then
        echo -n -e "\r Coupang Play:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r Coupang Play:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_NaverTV() {
    local ts=$(date +%s%3N)
    if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
        ts="$(date +%s)000"
    fi
    local base_url="https://apis.naver.com/"
    local key="nbxvs5nwNG9QKEWK0ADjYA4JZoujF4gHcIwvoCxFTPAeamq5eemvt5IWAYXxrbYM"
    local sign_text="https://apis.naver.com/now_web2/now_web_api/v1/clips/31030608/play-info${ts}"
    local signature=$(printf "%s" "${sign_text}" | openssl dgst -sha1 -hmac "${key}" -binary | openssl base64)
    local signature_encoded=$(printf "%s" "${signature}" | sed 's/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;s/\&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2a/g;s/+/%2b/g;s/,/%2c/g;s/\//%2f/g;s/:/%3a/g;s/;/%3b/g;s/=/%3d/g;s/?/%3f/g;s/@/%40/g;s/\[/%5b/g;s/\]/%5d/g')
    local req_url="${base_url}now_web2/now_web_api/v1/clips/31030608/play-info?msgpad=${ts}&md=${signature_encoded}"
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "${req_url}" --user-agent "${UA_Browser}" -H 'host: apis.naver.com' -H 'connection: keep-alive' -H "sec-ch-ua: ${UA_SecCHUA}" -H 'accept: application/json, text/plain, */*' -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' -H 'origin: https://tv.naver.com' -H 'sec-fetch-site: same-site' -H 'sec-fetch-mode: cors' -H 'sec-fetch-dest: empty' -H 'referer: https://tv.naver.com/v/31030608' -H 'accept-language: en,zh-CN;q=0.9,zh;q=0.8' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Naver TV:\t\t\t\t" "$1" "apis.naver.com"
        return
    fi
    local playable=$(echo "$tmpresult" | json_query . | grep -o '"playable": *"[^"]*"' | cut -d'"' -f4)

    if [[ "$playable" == "NOT_COUNTRY_AVAILABLE" ]] && [ -n "$playable" ]; then
        echo -n -e "\r Naver TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Naver TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Naver TV:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    return
    # local result=$(echo "$tmpresult" | json_query . | grep ctry | cut -f4 -d'"')
    # if [[ "$result" == "KR" ]]; then
    #     echo -n -e "\r Naver TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    # else
    #     echo -n -e "\r Naver TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    # fi
}

function MediaUnlockTest_Afreeca() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fSsL --max-time 10 "https://vod.afreecatv.com/player/97464151" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Afreeca TV:\t\t\t\t" "$1" "vod.afreecatv.com"
        return
    fi
    local result1=$(echo "$tmpresult" | grep "document.location.href='https://vod.afreecatv.com'" )
    if [ -z "$result1" ]; then
        echo -n -e "\r Afreeca TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    else
        echo -n -e "\r Afreeca TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_KBSDomestic() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fSsL --max-time 10 "https://vod.kbs.co.kr/index.html?source=episode&sname=vod&stype=vod&program_code=T2022-0690&program_id=PS-2022164275-01-000&broadcast_complete_yn=N&local_station_code=00&section_code=03" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "KBS Domestic:\t\t\t\t" "$1" "vod.kbs.co.kr"
        return
    fi
    local result1=$(echo "$tmpresult" | grep "ipck" | grep 'Domestic\\": true' )
    if [ -z "$result1" ]; then
        echo -n -e "\r KBS Domestic:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r KBS Domestic:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_SpotvNow() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}"  -Ss --max-time 10 'https://edge.api.brightcove.com/playback/v1/accounts/5764318566001/videos/6349973203112'   -H 'accept: application/json;pk=BCpkADawqM0U3mi_PT566m5lvtapzMq3Uy7ICGGjGB6v4Ske7ZX_ynzj8ePedQJhH36nym_5mbvSYeyyHOOdUsZovyg2XlhV6rRspyYPw_USVNLaR0fB_AAL2HSQlfuetIPiEzbUs1tpNF9NtQxt3BAPvXdOAsvy1ltLPWMVzJHiw9slpLRgI2NUufc' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "SPOTV NOW:\t\t\t\t" "$1" "edge.api.brightcove.com"
        return
    fi

    local result=$(echo $tmpresult | json_query .[0].error_subcode 2>/dev/null | tr -d '"')
    local region=$(echo $tmpresult | json_query .[0].client_geo 2>/dev/null | tr -d '"')
    if [[ "$result" == "CLIENT_GEO" ]]; then
        echo -n -e "\r SPOTV NOW:\t\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    elif [ -z "$result" ] && [ -n "$tmpresult" ]; then
        echo -n -e "\r SPOTV NOW:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r SPOTV NOW:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi

}

function MediaUnlockTest_KBSAmerican() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fSsL --max-time 10 "https://vod.kbs.co.kr/index.html?source=episode&sname=vod&stype=vod&program_code=T2022-0690&program_id=PS-2022164275-01-000&broadcast_complete_yn=N&local_station_code=00&section_code=03" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "KBS American:\t\t\t\t" "$1" "vod.kbs.co.kr"
        return
    fi
    local result1=$(echo "$tmpresult" | grep "ipck" | grep 'American\\": true' )
    if [ -z "$result1" ]; then
        echo -n -e "\r KBS American:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r KBS American:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_KOCOWA() {
    local result1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://www.kocowa.com/" 2>&1)
    if [[ "$result1" == "000" ]]; then
        print_network_failure "KOCOWA:\t\t\t\t" "$1" "www.kocowa.com"
        return
    fi
    if [[ "$result1" == "200" ]]; then
        echo -n -e "\r KOCOWA:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    else
        echo -n -e "\r KOCOWA:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_PandaTV() {
    local result1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://api.pandalive.co.kr/v1/live/play" 2>&1)
    if [[ "$result1" == "000" ]]; then
        print_network_failure "PandaTV:\t\t\t\t" "$1" "api.pandalive.co.kr"
        return
    fi
    if [[ "$result1" == "400" ]]; then
        echo -n -e "\r PandaTV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [[ "$result1" == "403" ]]; then
        echo -n -e "\r PandaTV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r PandaTV:\t\t\t\t${Font_Red}Unknown (Code: $result1)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_NBCTV(){
    local onetrustresult=$(curl $curlArgs -${1} -sS --user-agent "${UA_Browser}" --max-time 10 "https://geolocation.onetrust.com/cookieconsentpub/v1/geo/location/dnsfeed" 2>&1)
    if [[ "$onetrustresult" == "curl"* ]]; then
        print_network_failure "NBC TV:\t\t\t\t" "$1" "geolocation.onetrust.com"
        return
    elif [ -z "$onetrustresult" ]; then
        echo -n -e "\r NBC TV:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
    local result=$(echo $onetrustresult | grep '"country":"US"')
    if [ -z "$result" ]; then
        echo -n -e "\r NBC TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r NBC TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_AETV(){
    # Based on https://github.com/oneclickvirt/UnlockTests/blob/main/us/AETV.go
    # Each step falls through to the next when it cannot reach a verdict.
    local ua_edge="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36 Edg/144.0.0.0"
    local video_meta_token="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3Njk2NzU2NDAsImV4cCI6MTc2OTY3OTI0MCwicHBsSWQiOiIzMDU0ODkiLCJpc0JlaGluZFdhbGwiOmZhbHNlLCJpc0xvbmdGb3JtIjp0cnVlLCJlbmNvZGVyIjoiYml0bW92aW5fdjEiLCJyZW5kaXRpb25zTGlzdCI6bnVsbCwicmVuZGl0aW9uc1BhdGhQcmVmaXgiOiJiaXRtb3Zpbi9BRVROLUFFVFZfVk1TL0FFTl9PWlJLXzMwNTQ4OV9HTEJfNDkzNjY5XzIzOThfNjBfMjAyNTAxMDRfMDFfQUVUTi1BRVRWX1ZNUyIsInJlZ2lvbnNBdmFpbGFibGUiOlsiVVMiLCJDQSIsIkFTIiwiR1UiLCJNUCIsIlBSIiwiVkkiLCJVTSJdfQ._IBIJ-Yh8X9hGOGglCNQWcW6WZKrUbjTNQ8Rdon8u_A"
    local dai_data='dai-dlid=default_delivery_60101&afid=59946479&adobe_id=17218268117322661452685981206066538688&asnw=171213&caid=305489&imafw__fw_ae=nonauthenticated&imafw__fw_vcid2=2395239744222918&devicename=Desktop&imafw_csid=aetv.desktop.video&imafw__fw_player_height=901&imafw__fw_player_width=474&imafw__fw_us_privacy=1---&imafw__fw_site_page=https%3A%2F%2Fplay.aetv.com%2Fshows%2Fozark-law%2Fseason-1%2Fepisode-1&ltd=1&imafw__fw_h_user_agent=Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20Chrome%2F144.0.0.0%20Safari%2F537.36%20Edg%2F144.0.0.0&imafw_prof=171213%3Aaetn_desktop_ae_googlessai_vod&metr=1031&nw=171213&pvrn=7469863039993294&ssnw=171213&vprn=7469863039993294&flag=%2Bsltp%2Bvicb%2Bslcb%2Bamsl%2Bamcb%2Bssus%2Bemcr%2Bfbad%2Bdtrd%2Bplay&resp=vmap1&cld=1&ctv=0&correlator=3412237903465914&ptt=20&osd=2&sdr=1&sdki=41&sdkv=h.3.740.0&uach=WyJXaW5kb3dzIiwiMTUuMC4wIiwieDg2IiwiIiwiMTQ0LjAuMzcxOS45MiIsbnVsbCwwLG51bGwsIjY0IixbWyJOb3QoQTpCcmFuZCIsIjguMC4wLjAiXSxbIkNocm9taXVtIiwiMTQ0LjAuNzU1OS45NyJdLFsiTWljcm9zb2Z0IEVkZ2UiLCIxNDQuMC4zNzE5LjkyIl1dLDBd&ua=Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20Chrome%2F144.0.0.0%20Safari%2F537.36%20Edg%2F144.0.0.0&eid=44751890%2C95322027%2C95331589%2C95332046&frm=0&omid_p=Google1%2Fh.3.740.0&sdk_apis=7&sid=6C436384-F48F-4AEA-8FCA-9F3633757A74&ssss=gima&ref=https%3A%2F%2Fplay.aetv.com%2Fshows%2Fozark-law%2Fseason-1%2Fepisode-1&url=https%3A%2F%2Fplay.aetv.com%2Fshows%2Fozark-law%2Fseason-1%2Fepisode-1&wta=0&us_privacy=1---&gpp_sid=-1&eoidce=1'

    # Step 1: Google DAI stream -> Argus API. JWTExpiredSignature means the geo check already passed.
    local dai=$(curl $curlArgs -${1} --user-agent "${ua_edge}" -sS --max-time 10 -X POST "https://dai.google.com/ondemand/hls/content/2540935/vid/2400478275868/streams" \
        -H "accept: */*" \
        -H "content-type: application/x-www-form-urlencoded;charset=UTF-8" \
        -H "origin: https://play.aetv.com" \
        -H "referer: https://play.aetv.com/" \
        --data "$dai_data" 2>&1)
    local manifest=$(echo "$dai" | json_query -r '.stream_manifest // empty')
    # originpath is kept URL-encoded, as it is passed on as a query value again.
    local origin_path=$(echo "$manifest" | sed -n 's/.*[?&]originpath=\([^&]*\).*/\1/p')
    if [ -n "$origin_path" ]; then
        local argus=$(curl $curlArgs -${1} --user-agent "${ua_edge}" -sS --max-time 10 -w '\n%{http_code}' \
            "https://argus.media.aetnd.com/?bestCdn=fastly&brand=aetv&client=tve-web-theo&dfpOp=${origin_path}&sig=00697b29892c60831e3de250beaec91bd6ab73901a0ffb723b533130425058484d6c62" \
            -H "accept: */*" \
            -H "origin: https://play.aetv.com" \
            -H "referer: https://play.aetv.com/" \
            -H "x-video-meta-token: ${video_meta_token}" 2>&1)
        if [[ "${argus##*$'\n'}" == "403" ]]; then
            local exception=$(echo "${argus%$'\n'*}" | json_query -r '.exception // empty')
            if [[ "$exception" == "GeoLocationBlocked" ]]; then
                echo -n -e "\r A&E TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
                return
            elif [[ "$exception" == "JWTExpiredSignature" ]]; then
                echo -n -e "\r A&E TV:\t\t\t\t${Font_Green}Yes (Region: US)${Font_Suffix}\n"
                return
            fi
        fi
    fi

    # Step 2: country code in the homepage meta tag.
    local homepage=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://www.aetv.com/" 2>&1)
    local homepage_failed=""
    [[ "$homepage" == "curl"* ]] && homepage_failed=1
    local region=$(echo "$homepage" | sed -n -E "s/.*<meta[[:space:]]+name=[\"']aetn:countryCode[\"'][[:space:]]+content=[\"']([A-Z]{2})[\"'].*/\1/p" | head -n 1)
    if [[ "$region" == "US" ]]; then
        echo -n -e "\r A&E TV:\t\t\t\t${Font_Green}Yes (Region: US)${Font_Suffix}\n"
        return
    elif [ -n "$region" ]; then
        echo -n -e "\r A&E TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    # Step 3: geolocation used by the site's privacy manager.
    local geo_country=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://geo.privacymanager.io/" 2>&1 | json_query -r '.country // empty')
    if [[ "$geo_country" == "US" ]] || [[ "$geo_country" == "CA" ]]; then
        echo -n -e "\r A&E TV:\t\t\t\t${Font_Green}Yes (Region: ${geo_country})${Font_Suffix}\n"
        return
    fi

    # Step 4: thePlatform reports geo blocking explicitly.
    local platform=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -X POST "https://link.theplatform.com/s/xc6n8B/UR27JDU0bu2s/" 2>&1)
    if [[ "$platform" == *"GeoLocationBlocked"* ]]; then
        echo -n -e "\r A&E TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    # Step 5: country cookie set by play.aetv.com.
    local play=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS -i --max-time 10 -X POST "https://play.aetv.com/" 2>&1)
    local play_region=$(echo "$play" | sed -n -E 's/.*AETN-Country-Code=([A-Z]+).*/\1/p' | head -n 1)
    if [[ "$play_region" == "US" ]] || [[ "$play_region" == "CA" ]]; then
        echo -n -e "\r A&E TV:\t\t\t\t${Font_Green}Yes (Region: ${play_region})${Font_Suffix}\n"
        return
    elif [ -n "$play_region" ]; then
        echo -n -e "\r A&E TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    if [ -n "$homepage_failed" ] && [[ "$play" == "curl"* ]]; then
        print_network_failure "A&E TV:\t\t\t\t" "$1" "www.aetv.com"
        return
    fi
    echo -n -e "\r A&E TV:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_NFLPlus() {
    local tmpresult=$(curl $curlArgs -${1} -fsL -w "%{http_code}\n%{url_effective}\n" -o /dev/null "https://www.nfl.com/plus/" 2>&1)
    if [[ "$tmpresult" == "000"* ]]; then
        print_network_failure "NFL+:\t\t\t\t\t" "$1" "www.nfl.com"
        return
    fi
    local result=$(echo $tmpresult | grep 'nflgamepass')
    if [ -n "$result" ]; then
        echo -n -e "\r NFL+:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r NFL+:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_SkyShowTime(){
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fSsi --max-time 10 "https://www.skyshowtime.com/" -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "SkyShowTime:\t\t\t\t" "$1" "www.skyshowtime.com"
        return
    fi

    local result1=$(echo "$tmpresult" | grep 'location' | head -1 | awk '{print $2}' )
    if [[ "$result1" == *"where-can-i-stream"* ]]; then
    	echo -n -e "\r SkyShowTime:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
    	local region1=$(echo -n "$result1" | sed 's#https://www.skyshowtime.com/\([0-9a-zA-Z][0-9a-zA-Z]\)?\r#\1#i' | tr 'a-z' 'A-Z' )
        echo -n -e "\r SkyShowTime:\t\t\t\t${Font_Green}Yes (Region: ${region1})${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_MathsSpot() {
    local tmpresult1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://netv2.now.gg/v3/playtoken" 2>&1)
    if [[ "$tmpresult1" == "curl"* ]]; then
        print_network_failure "Maths Spot:\t\t\t\t" "$1" "netv2.now.gg"
        return
    fi
    local blocked=$(echo "$tmpresult1" | grep 'Request blocked')
    if [ -n "$blocked" ]; then
    	echo -n -e "\r Maths Spot:\t\t\t\t${Font_Red}No  (Proxy/VPN Detected)${Font_Suffix}\n"
        return
    fi
    local playtoken=$(echo "$tmpresult1" | json_query . | grep '"playToken":' | awk '{print $2}' | cut -f2 -d'"')
    local region=$(echo "$tmpresult1" | json_query . | grep '"countryCode":' | awk '{print $2}' | cut -f2 -d'"')
    local host=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://mathsspot.com/2/api/play/v1/startSession?uaId=ua-KzV6fgcCBHQDU9DHCt2uG&uaSessionId=uasess-IdEux1e80EUstUlnnnHG0&appId=5349&initialOrientation=landscape&utmSource=NA&utmMedium=NA&utmCampaign=NA&deviceType=&playToken=${playtoken}&deepLinkUrl=&accessCode=" 2>&1)
    local tmpresult2=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://mathsspot.com/2/api/play/v1/startSession?uaId=ua-KzV6fgcCBHQDU9DHCt2uG&uaSessionId=uasess-IdEux1e80EUstUlnnnHG0&appId=5349&initialOrientation=landscape&utmSource=NA&utmMedium=NA&utmCampaign=NA&deviceType=&playToken=${playtoken}&deepLinkUrl=&accessCode=" -H "x-ngg-fe-version: ${host}" 2>&1)
    if [[ "$host" == "curl"* ]] || [[ "$tmpresult2" == "curl"* ]]; then
        print_network_failure "Maths Spot:\t\t\t\t" "$1" "mathsspot.com"
        return
    fi
    local result=$(echo "$tmpresult2" | json_query . | grep '"status":' | awk '{print $2}' | cut -f2 -d'"')
    if [[ "$result" == "FailureServiceNotInRegion" ]]; then
    	echo -n -e "\r Maths Spot:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    elif [[ "$result" == "Success" ]]; then
        echo -n -e "\r Maths Spot:\t\t\t\t${Font_Green}Yes (Region: ${region})${Font_Suffix}\n"
    else
    	echo -n -e "\r Maths Spot:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
    fi
}

function MediaUnblockTest_BGlobalSEA() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://api.bilibili.tv/intl/gateway/web/playurl?s_locale=en_US&platform=web&ep_id=347666" 2>&1)
    local result1="$(echo "${result}" | json_query . | grep '"code"' | head -1 | awk '{print $2}' | cut -d ',' -f1)"
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "B-Global SouthEastAsia:\t\t" "$1" "api.bilibili.tv"
        return
    fi
    if [[ "$result1" == "0" ]]; then
        echo -n -e "\r B-Global SouthEastAsia:\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r B-Global SouthEastAsia:\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r B-Global SouthEastAsia:\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnblockTest_BGlobalTH() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://api.bilibili.tv/intl/gateway/web/playurl?s_locale=en_US&platform=web&ep_id=10077726" 2>&1)
    local result1="$(echo "${result}" | json_query . | grep '"code"' | head -1 | awk '{print $2}' | cut -d ',' -f1)"
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "B-Global Thailand Only:\t\t" "$1" "api.bilibili.tv"
        return
    fi
    if [[ "$result1" == "0" ]]; then
        echo -n -e "\r B-Global Thailand Only:\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r B-Global Thailand Only:\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r B-Global Thailand Only:\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnblockTest_BGlobalID() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://api.bilibili.tv/intl/gateway/web/playurl?s_locale=en_US&platform=web&ep_id=11130043" 2>&1)
    local result1="$(echo "${result}" | json_query . | grep '"code"' | head -1 | awk '{print $2}' | cut -d ',' -f1)"
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "B-Global Indonesia Only:\t\t" "$1" "api.bilibili.tv"
        return
    fi
    if [[ "$result1" == "0" ]]; then
        echo -n -e "\r B-Global Indonesia Only:\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r B-Global Indonesia Only:\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r B-Global Indonesia Only:\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnblockTest_BGlobalVN() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://api.bilibili.tv/intl/gateway/web/playurl?s_locale=en_US&platform=web&ep_id=11405745" 2>&1)
    local result1="$(echo "${result}" | json_query . | grep '"code"' | head -1 | awk '{print $2}' | cut -d ',' -f1)"
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "B-Global Việt Nam Only:\t\t" "$1" "api.bilibili.tv"
        return
    fi
    if [[ "$result1" == "0" ]]; then
        echo -n -e "\r B-Global Việt Nam Only:\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r B-Global Việt Nam Only:\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r B-Global Việt Nam Only:\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_AISPlay() {
    local result=$(curl $curlArgs -${1} -sSLI --max-time 10 "https://49-231-37-237-rewriter.ais-vidnt.com/ais/play/origin/VOD/playlist/ais-yMzNH1-bGUxc/index.m3u8" 2>&1)
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "AIS Play:\t\t\t\t" "$1" "49-231-37-237-rewriter.ais-vidnt.com"
        return
    fi
    local result1="$(echo "${result}" | grep 'X-Geo-Protection-System-Status' | awk '{print $2}' )"
    if [[ "$result1" == *"ALLOW"* ]]; then
        echo -n -e "\r AIS Play:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result1" == *"BLOCK"* ]]; then
        echo -n -e "\r AIS Play:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r AIS Play:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_TrueID() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://movie.trueid.net/apis/auth/checkedplay" -X POST -d '{"lang":"th","cmsId":"gROjxLzNBJb6","contentType":"movie"}' -H "Authorization: Basic YmJjNjI5Yzk3OTEzMDNhMmNjYzcyMWQzYTJlNGRkOGFiZWZkN2ZhNzoxMzAzYTJjY2M3MjFkM2EyZTRkZDhhYmVmZDdmYTc=" 2>&1)
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "TrueID:\t\t\t\t" "$1" "movie.trueid.net"
        return
    fi
    local result1="$(echo "${result}" | json_query . | grep 'billboardType' | awk '{print $2}' )"
    if [[ "$result1" == *"GEO_BLOCK"* ]]; then
        echo -n -e "\r TrueID:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r TrueID:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r TrueID:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_meWATCH() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://cdn.mewatch.sg/api/items/362414/videos?delivery=stream%2Cprogressive&ff=idp%2Cldp%2Crpt%2Ccd&lang=en&resolution=External&segments=all" 2>&1)
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "meWATCH:\t\t\t\t" "$1" "cdn.mewatch.sg"
        return
    fi
    if [[ "$result" == *"location that is not permitted"* ]]; then
        echo -n -e "\r meWATCH:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r meWATCH:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r meWATCH:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_VTVcab() {
    # Unfinished.
    local token=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSLI --max-time 10 "https://www.vtvcab.vn/" 2>&1 | grep "token" | grep -Eo 'token=([^;]*)' | tr -d "token=")
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://apigwon.gviet.vn/sdp-vod/api/v1/source" -H "authorization: ${token}" 2>&1)
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "VTVcab:\t\t\t\t" "$1" "apigwon.gviet.vn"
        return
    fi
    echo $result > debug.logs
    if [[ "$result" == *"4006"* ]]; then
        echo -n -e "\r VTVcab:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r VTVcab:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r VTVcab:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_Vidio() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://geo-id-media-001-vidio-com.akamaized.net/2x2.png" 2>&1)
    if [[ "$result" == "000" ]]; then
        print_network_failure "Vidio:\t\t\t\t\t" "$1" "geo-id-media-001-vidio-com.akamaized.net"
        return
    fi
    if [[ "$result" == "200" ]]; then
        echo -n -e "\r Vidio:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Vidio:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Vidio:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_TataPlay() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://watch.tataplay.com/" 2>&1)
    if [[ "$result" == "000" ]]; then
        print_network_failure "Tata Play:\t\t\t\t" "$1" "watch.tataplay.com"
        return
    fi
    if [[ "$result" == "200" ]]; then
        echo -n -e "\r Tata Play:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Tata Play:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Tata Play:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_MXPlayer() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://www.mxplayer.in/" 2>&1)
    if [[ "$result" == *"curl"* ]]; then
        print_network_failure "MXPlayer:\t\t\t\t" "$1" "www.mxplayer.in"
        return
    fi
    if [[ "$result" == *"We are currently not available in your region"* ]]; then
        echo -n -e "\r MXPlayer:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r MXPlayer:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r MXPlayer:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_ClipTV() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://cliptv.vn/the-forgiven-2022,lvDoN0JrP/Jx52YAKL2v" 2>&1)
    if [[ "$result" == *"curl"* ]]; then
        print_network_failure "Clip TV:\t\t\t\t" "$1" "cliptv.vn"
        return
    fi
    if [[ "$result" == *"Sorry, this video is not available in your country."* ]]; then
        echo -n -e "\r Clip TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Clip TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Clip TV:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_GalaxyPlay() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://api.glxplay.io/account/device/new" 2>&1)
    if [[ "$result" == *"curl"* ]]; then
        print_network_failure "Galaxy Play:\t\t\t\t" "$1" "api.glxplay.io"
        return
    fi
    if [[ "$result" == *"495"* ]]; then
        echo -n -e "\r Galaxy Play:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Galaxy Play:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Galaxy Play:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_MYTV() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 "https://webapi.mytv.vn/api/v1/movie/138546/play?" -X POST -d "partition=1" 2>&1)
    if [[ "$result" == *"curl"* ]]; then
        print_network_failure "MYTV:\t\t\t\t\t" "$1" "webapi.mytv.vn"
        return
    fi
    local result1="$(echo "${result}" | json_query . | grep 'result' | awk '{print $2}'| tr -d "," )"
    if [[ "$result1" == "103" ]]; then
        echo -n -e "\r MYTV:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r MYTV:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r MYTV:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_Google() {
    local tmp=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 'https://bard.google.com/_/BardChatUi/data/batchexecute'   -H 'accept-language: en-US'   --data-raw 'f.req=[[["K4WWud","[[0],[\"en-US\"]]",null,"generic"]]]' 2>&1)
    if [[ "$tmp" == "curl"* ]]; then
        print_network_failure "Google Location:\t\t\t" "$1" "bard.google.com"
        return
    fi
    local region=$(echo "$tmp" | grep K4WWud | json_query .[0][2] | grep -Eo '\[\[\\"(.*)\\",\\"S' )
    echo -n -e "\r Google Location:\t\t\t${Font_Green}$(trim_chars "$region" 4 6)${Font_Suffix}\n"
}

function WebTest_GoogleSearchCAPTCHA() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 'https://www.google.com/search?q=curl&oq=curl&sourceid=chrome&ie=UTF-8' \
        -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' -H 'accept-language: en-US,en;q=0.9' \
        -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' \
        -H 'sec-fetch-site: none' -H 'sec-fetch-user: ?1' -H 'upgrade-insecure-requests: 1' 2>&1)
    if [[ "$tmpresult" == "curl"* ]] || [ -z "$tmpresult" ]; then
        print_network_failure "Google Search CAPTCHA Free:\t\t" "$1" "www.google.com"
        return
    fi

    local isBlocked=$(echo "$tmpresult" | grep -iE 'unusual traffic from|is blocked|unaddressed abuse')
    local isOK=$(echo "$tmpresult" | grep -i 'curl')

    if [ -n "$isBlocked" ]; then
        echo -n -e "\r Google Search CAPTCHA Free:\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    if [ -n "$isOK" ]; then
        echo -n -e "\r Google Search CAPTCHA Free:\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Google Search CAPTCHA Free:\t\t${Font_Red}Failed (Error: PAGE ERROR)${Font_Suffix}\n"
}

function MediaUnlockTest_GooglePlayStore() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 -w '\n%{http_code}' "https://play.google.com/store/games" \
        -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
        -H 'accept-language: en-US;q=0.9' -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' -H 'sec-fetch-site: none' -H 'sec-fetch-user: ?1' -H 'upgrade-insecure-requests: 1' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Google Play Store:\t\t\t" "$1" "play.google.com"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    if [[ "$httpcode" != "200" ]]; then
        echo -n -e "\r Google Play Store:\t\t\t${Font_Red}Failed (Unexpected Result: ${httpcode})${Font_Suffix}\n"
        return
    fi
    local region=$(echo "$tmpresult" | grep -Eo '"zQmIje" *: *"[^"]+"' | head -n1 | cut -d'"' -f4)
    if [ -z "$region" ]; then
        region=$(echo "$tmpresult" | grep -Eo '<div class="yVZQTb">[^<(]+' | head -n1 | sed 's/.*>//; s/ *$//')
    fi
    if [ -z "$region" ]; then
        echo -n -e "\r Google Play Store:\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    if [[ "$(to_upper "$region")" == "CN" ]]; then
        echo -n -e "\r Google Play Store:\t\t\t${Font_Red}No  (Region: CN)${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Google Play Store:\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
}

function MediaUnlockTest_GoogleGemini() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 -w '\n%{http_code}' "https://gemini.google.com" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Google Gemini:\t\t\t\t" "$1" "gemini.google.com"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    if [[ "$httpcode" == "403" ]] || [[ "$httpcode" == "451" ]]; then
        echo -n -e "\r Google Gemini:\t\t\t\t${Font_Red}No  (Banned)${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" != "200" ]]; then
        echo -n -e "\r Google Gemini:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    # The page reports the ISO 3166-1 alpha-3 code; only supported countries are mapped to alpha-2.
    local region3=$(echo "$tmpresult" | grep -Eo ',2,1,200,"[A-Z]{3}"' | head -n1 | cut -d'"' -f2)
    local supported="ABW:AW AGO:AO AIA:AI ALA:AX ALB:AL AND:AD ARE:AE ARG:AR ARM:AM ASM:AS ATA:AQ ATF:TF ATG:AG AUS:AU AUT:AT AZE:AZ BDI:BI BEL:BE BEN:BJ BES:BQ BFA:BF BGD:BD BGR:BG BHR:BH BHS:BS BIH:BA BLM:BL BLZ:BZ BMU:BM BOL:BO BRA:BR BRB:BB BRN:BN BTN:BT BWA:BW CAF:CF CAN:CA CCK:CC CHE:CH CHL:CL CIV:CI CMR:CM COD:CD COG:CG COK:CK COL:CO COM:KM CPV:CV CRI:CR CUW:CW CXR:CX CYM:KY CYP:CY CZE:CZ DEU:DE DJI:DJ DMA:DM DNK:DK DOM:DO DZA:DZ ECU:EC EGY:EG ERI:ER ESH:EH ESP:ES EST:EE ETH:ET FIN:FI FJI:FJ FLK:FK FRA:FR FRO:FO FSM:FM GAB:GA GBR:GB GEO:GE GGY:GG GHA:GH GIB:GI GIN:GN GLP:GP GMB:GM GNB:GW GNQ:GQ GRC:GR GRD:GD GRL:GL GTM:GT GUF:GF GUM:GU GUY:GY HKG:HK HMD:HM HND:HN HRV:HR HTI:HT HUN:HU IDN:ID IMN:IM IND:IN IOT:IO IRL:IE IRQ:IQ ISL:IS ISR:IL ITA:IT JAM:JM JEY:JE JOR:JO JPN:JP KAZ:KZ KEN:KE KGZ:KG KHM:KH KIR:KI KNA:KN KOR:KR KWT:KW LAO:LA LBN:LB LBR:LR LBY:LY LCA:LC LIE:LI LKA:LK LSO:LS LTU:LT LUX:LU LVA:LV MAC:MO MAF:MF MAR:MA MCO:MC MDA:MD MDG:MG MDV:MV MEX:MX MHL:MH MKD:MK MLI:ML MLT:MT MMR:MM MNE:ME MNG:MN MNP:MP MOZ:MZ MRT:MR MSR:MS MTQ:MQ MUS:MU MWI:MW MYS:MY MYT:YT NAM:NA NCL:NC NER:NE NFK:NF NGA:NG NIC:NI NIU:NU NLD:NL NOR:NO NPL:NP NRU:NR NZL:NZ OMN:OM PAK:PK PAN:PA PCN:PN PER:PE PHL:PH PLW:PW PNG:PG POL:PL PRI:PR PRT:PT PRY:PY PSE:PS PYF:PF QAT:QA REU:RE ROU:RO RWA:RW SAU:SA SDN:SD SEN:SN SGP:SG SGS:GS SHN:SH SJM:SJ SLB:SB SLE:SL SLV:SV SMR:SM SOM:SO SPM:PM SRB:RS SSD:SS STP:ST SUR:SR SVK:SK SVN:SI SWE:SE SWZ:SZ SXM:SX SYC:SC TCA:TC TCD:TD TGO:TG THA:TH TJK:TJ TKL:TK TKM:TM TLS:TL TON:TO TTO:TT TUN:TN TUR:TR TUV:TV TWN:TW TZA:TZ UGA:UG UKR:UA UMI:UM URY:UY USA:US UZB:UZ VAT:VA VCT:VC VEN:VE VGB:VG VIR:VI VNM:VN VUT:VU WLF:WF WSM:WS XKX:XK YEM:YE ZAF:ZA ZMB:ZM ZWE:ZW"
    local region=$(echo " $supported " | grep -Eo " ${region3:-NONE}:[A-Z]{2} " | cut -d: -f2 | tr -d ' ')
    if [ -n "$region" ]; then
        echo -n -e "\r Google Gemini:\t\t\t\t${Font_Green}Yes (Region: ${region})${Font_Suffix}\n"
        return
    fi
    if [[ "$tmpresult" == *"45631641,null,true"* ]] || [[ "$tmpresult" == *"45617354,null,true"* ]]; then
        echo -n -e "\r Google Gemini:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi
    if [ -n "$region3" ]; then
        echo -n -e "\r Google Gemini:\t\t\t\t${Font_Red}No  (Region: ${region3})${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Google Gemini:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
}

function MediaUnlockTest_NHKPlus() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://location-plus.nhk.jp/geoip/area.json" 2>&1)
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "NHK+:\t\t\t\t\t" "$1" "location-plus.nhk.jp"
        return
    fi
    local result1="$(echo "${result}" | json_query . | grep "country_code" | awk '{print $2}' | cut -d '"' -f 2)"
    if [[ "$result1" == "JP" ]]; then
        echo -n -e "\r NHK+:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r NHK+:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r NHK+:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_Tiktok() {
    local page=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 -w '\n%{url_effective}' "https://www.tiktok.com/" 2>&1)
    if [[ "$page" == "curl"* ]]; then
        print_network_failure "Tiktok:\t\t\t\t" "$1" "www.tiktok.com"
        return
    fi
    local result="${page##*$'\n'}"
    page="${page%$'\n'*}"
    # Do not follow redirects: in blocked regions store_region 302s to /<region>/about,
    # and re-POSTing there returns 405. The region is then taken from the redirect URL.
    local result1=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sS --max-time 10 -X POST -w '##REDIRECT##%{redirect_url}' "https://www.tiktok.com/passport/web/store_region/" 2>&1)
    local redirect="${result1##*##REDIRECT##}"
    result1="${result1%##REDIRECT##*}"
    local region=""
    if [[ -z "$redirect" ]]; then
        region="$(echo "${result1}" | json_query ".data.store_region" | tr -d '"')"
    elif [[ "$redirect" =~ tiktok\.com/([a-zA-Z]{2})/ ]]; then
        region="${BASH_REMATCH[1]}"
    fi
    # Fallback: the web app embeds the region in its rehydration data, e.g. "region":"US"
    if [[ -z "$region" ]]; then
        region="$(printf '%s' "$page" | grep -oE '"(storeRegion|region)":"[A-Za-z]{2}"' | head -n 1 | cut -d'"' -f4)"
    fi
    if [[ -z "$region" ]] && [ -n "$DEBUG" ]; then
        echo "[${FUNCNAME[0]}] no region found; url_effective=${result}; store_region=$(printf '%s' "$result1" | head -c 300 | tr -d '\n')" >&2
    fi
    if [[ "$result" == *"/about"* ]] || [[ "$result" == *"/status"* ]] || [[ "$result" == *"landing"* ]]; then
        if [[ "$region" == "cn" ]]; then
            echo -n -e "\r Tiktok:\t\t\t\t${Font_Yellow}Provided by Douyin${Font_Suffix}\n"
            return
        else
            echo -n -e "\r Tiktok:\t\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r Tiktok:\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Tiktok:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_StarhubTVPlus() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSL --max-time 10  --output /dev/null -w %{http_code} "https://ucdn.starhubgo.com/bpk-tv/HubSensasiHD/output/manifest.mpd" 2>&1)
    if [[ "$result" == "000"* || "$result" == "curl"* ]]; then
        print_network_failure "Starhub TV+:\t\t\t\t" "$1" "ucdn.starhubgo.com"
        return
    fi
    if [[ "$result" == "200" ]]; then
        echo -n -e "\r Starhub TV+:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Starhub TV+:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Starhub TV+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_KPlus() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSL --max-time 10 -X POST -d '{"osVersion":"Windows 10","deviceModel":"Edge","deviceType":"PC","deviceSerial":"w7ab83550-c0aa-11ee-bf07-531681e47537","deviceOem":"Edge","devicePrettyName":"Edge 121.0.0.0","appVersion":"11.0","language":"en_US","brand":"vstv","featureLevel":5}' "https://tvapi-sgn.solocoo.tv/v1/provision" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "K+:\t\t\t\t\t" "$1" "tvapi-sgn.solocoo.tv"
        return
    fi
    local region=$(echo "${tmpresult}" | json_query .session.geoCountryCode | tr -d '"')
    if [[ "$region" == "VN" ]]; then
        echo -n -e "\r K+:\t\t\t\t\t${Font_Green}Yes (Region:${region})${Font_Suffix}\n"
        return
    else
        echo -n -e "\r K+:\t\t\t\t\t${Font_Red}No  (Region:${region})${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r K+:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_TV360() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSL --max-time 10 'https://tv360.vn/public/v1/composite/get-link?sq=CJSkRii71PAn41F9A2OlJSTxkOTDBl8uip04KFxqJc6iAmCPOt52q12a9hpwORZGjayWYrJSGjwYdG7Jy2NqPA%3D%3D&secured=true' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "TV360:\t\t\t\t\t" "$1" "tv360.vn"
        return
    fi
    local errcode=$(echo "${tmpresult}" | json_query .errorCode)
    if [[ "$errcode" == "310" ]]; then
        echo -n -e "\r TV360:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r TV360:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r TV360:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_SonyLiv() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSL --max-time 10 'https://www.sonyliv.com/signin' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "SonyLiv:\t\t\t\t" "$1" "www.sonyliv.com"
        return
    fi
    local country=$(echo "${tmpresult}" | grep country_code | grep -Eo 'country_code:...')
    if [[ "$country" == *"IN" ]]; then
        echo -n -e "\r SonyLiv:\t\t\t\t${Font_Green}Yes (Region:${country#*\"})${Font_Suffix}\n"
        return
    else
        echo -n -e "\r SonyLiv:\t\t\t\t${Font_Red}No  (Region:${country#*\"})${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r SonyLiv:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_JioCinema() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSL --max-time 10 'https://content-jiovoot.voot.com/psapi/' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Jio Cinema:\t\t\t\t" "$1" "content-jiovoot.voot.com"
        return
    fi
    local code=$(echo "${tmpresult}" | json_query .code)
    if [[ "$code" == "474" ]]; then
        echo -n -e "\r Jio Cinema:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Jio Cinema:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Jio Cinema:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_Zee5() {
    local tmpresult=$(curl $curlArgs -${1} -sLi 'https://www.zee5.com/' -w "_TAG_%{http_code}_TAG_" -H 'Upgrade-Insecure-Requests: 1' --user-agent "${UA_Browser}")
    local httpCode=$(echo "$tmpresult" | grep '_TAG_' | awk -F'_TAG_' '{print $2}')
    if [ "$httpCode" == '000' ]; then
        print_network_failure "Zee5:\t\t\t\t\t" "$1" "www.zee5.com"
        return
    fi

    local region=$(echo "$tmpresult" | grep -oE '(^|[^A-Za-z0-9_])country=[A-Z]{2}([^A-Za-z0-9_]|$)' | head -n 1 | grep -oE 'country=[A-Z]{2}' | cut -d'=' -f2)
    if [ -n "$region" ]; then
        echo -n -e "\r Zee5:\t\t\t\t\t${Font_Green}Yes (Region: ${region})${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Zee5:\t\t\t\t\t${Font_Red}Failed (Error: Unknown)${Font_Suffix}\n"
}

function MediaUnlockTest_HoyTV() {
    local result=$(curl $curlArgs -${1} -SsL --write-out %{http_code} --output /dev/null --max-time 10 "https://hoytv-live-stream.hoy.tv/ch78/index-fhd.m3u8" 2>&1)

    if [[ "$result" == "403" ]]; then
        echo -n -e "\r HOY TV:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$result" == "200" ]]; then
        echo -n -e "\r HOY TV:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "HOY TV:\t\t\t\t" "$1" "hoytv-live-stream.hoy.tv"
    return

}

function MediaUnlockTest_Eurosport() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSI --max-time 10 "https://www.eurosport.com/" 2>&1)
    # echo ${result: -2}
    if [[ "$result" == "curl"* ]]; then
        print_network_failure "Eurosports Region:\t\t\t" "$1" "www.eurosport.com"
        return
    fi
    local region=$(echo $result | grep eurosport_country_code | grep -Eo "eurosport_country_code=..")
    # if [[ "$result" == "200" ]]; then
    echo -n -e "\r Eurosports Region:\t\t\t${Font_Green}${region: -2}${Font_Suffix}\n"
    #     return
    # else
    #     echo -n -e "\r Starhub TV+:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    #     return
    # fi

    # echo -n -e "\r Starhub TV+:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_Viaplay() {
    local result1=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sSL --max-time 10 --write-out "%{url_effective}" --output /dev/null "https://viaplay.pl/package?recommended=viaplay" 2>&1)
    local result2=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -sS --max-time 10 --write-out %{redirect_url} --output /dev/null https://viaplay.com/ 2>&1)
    if [[ "$result1" == "curl"* ]] || [[ "$result2" == "curl"* ]]; then
        print_network_failure "Viaplay:\t\t\t\t" "$1" "viaplay.pl"
        return
    fi
    if [[ "$result1" == *"region-blocked"* ]]; then
        echo -n -e "\r Viaplay:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        local region=$(echo $result2 | awk -F"/" '{print $4}')
        echo -n -e "\r Viaplay:\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Viaplay:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_Sooka() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsL --max-time 10 --write-out %{http_code} --output /dev/null --max-time 10 "https://app-expmanager-proxy.sooka.my/prod/api/v1/enveu_prod/screen?screenId=0" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Sooka:\t\t\t\t\t" "$1" "app-expmanager-proxy.sooka.my"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r Sooka:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "403" ]; then
        echo -n -e "\r Sooka:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Sooka:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_BilibiliAnimeNew() {
    local tmp=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://api.bilibili.com/x/web-interface/zone" 2>&1)
    if [[ "$tmp" == "curl"* ]]; then
        print_network_failure "Bilibili Anime:\t\t\t" "$1" "api.bilibili.com"
        return
    fi
    local country_code=$(echo $tmp | json_query '.data.country_code')
    if [ "$country_code" == "86" ]; then
        echo -n -e "\r Bilibili Anime:\t\t\t${Font_Green}Yes (Region: CN)${Font_Suffix}\n"
        return
    elif [ "$country_code" == "886" ]; then
        echo -n -e "\r Bilibili Anime:\t\t\t${Font_Green}Yes (Region: TW)${Font_Suffix}\n"
        return
    elif [ "$country_code" == "852" ]; then
        echo -n -e "\r Bilibili Anime:\t\t\t${Font_Green}Yes (Region: HK)${Font_Suffix}\n"
        return
    elif [ "$country_code" == "853" ]; then
        echo -n -e "\r Bilibili Anime:\t\t\t${Font_Green}Yes (Region: MO)${Font_Suffix}\n"
        return
    else
        local country=$(echo $tmp | json_query '.data.country' | tr -d '"' )
        echo -n -e "\r Bilibili Anime:\t\t\t${Font_Yellow}Overseas (Country: $country)${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_ChatGPT() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsLI --max-time 10 "https://chatgpt.com" 2>&1)
    local tmpresult1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://ios.chat.openai.com" 2>&1)
    local cf_details=$(echo "$tmpresult1" | json_query .cf_details)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "ChatGPT:\t\t\t\t" "$1" "chatgpt.com"
        return
    fi

    local result1=$(echo "$tmpresult" | grep 'location' )
    if [ ! -n "$result1" ]; then
        if [[ "$tmpresult1" == *"blocked_why_headline"* ]]; then
            echo -n -e "\r ChatGPT:\t\t\t\t${Font_Red}No  (Blocked)${Font_Suffix}\n"
            return
        fi
        if [[ "$tmpresult1" == *"unsupported_country_region_territory"* ]]; then
            echo -n -e "\r ChatGPT:\t\t\t\t${Font_Red}No  (Unsupported Region)${Font_Suffix}\n"
            return
        fi
        if [[ "$cf_details" == *"(1)"* ]]; then
            echo -n -e "\r ChatGPT:\t\t\t\t${Font_Red}No  (Disallowed ISP[1])${Font_Suffix}\n"
            return
        fi
        if [[ "$cf_details" == *"(2)"* ]]; then
            echo -n -e "\r ChatGPT:\t\t\t\t${Font_Red}No  (Disallowed ISP[2])${Font_Suffix}\n"
            return
        fi
    	echo -n -e "\r ChatGPT:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
    	local region1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://chatgpt.com/cdn-cgi/trace" 2>&1 | grep "loc=" | awk -F= '{print $2}')
        if [[ "$cf_details" == *"(1)"* ]]; then
            echo -n -e "\r ChatGPT:\t\t\t\t${Font_Yellow}Web Only (Disallowed ISP[1])${Font_Suffix}\n"
            return
        fi
        if [[ "$cf_details" == *"(2)"* ]]; then
            echo -n -e "\r ChatGPT:\t\t\t\t${Font_Yellow}Web Only (Disallowed ISP[2])${Font_Suffix}\n"
            return
        fi
        echo -n -e "\r ChatGPT:\t\t\t\t${Font_Green}Yes (Region: ${region1})${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Sora() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsLI --max-time 10 "https://sora.com" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Sora:\t\t\t\t\t" "$1" "sora.com"
        return
    fi
    local result1=$(echo "$tmpresult" | grep 'location'  )
    if [ ! -n "$result1" ]; then
    	echo -n -e "\r Sora:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
    	local region1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://sora.com/cdn-cgi/trace" 2>&1 | grep "loc=" | awk -F= '{print $2}')
        echo -n -e "\r Sora:\t\t\t\t\t${Font_Green}Yes (Region: ${region1})${Font_Suffix}\n"
    fi
}

function AIUnlockTest_Gemini_location() {
    local tmp=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 'https://gemini.google.com/_/BardChatUi/data/batchexecute'   -H 'accept-language: en-US'   --data-raw 'f.req=[[["K4WWud","[[0],[\"en-US\"]]",null,"generic"]]]' 2>&1)
    if [[ "$tmp" == "curl"* ]]; then
        print_network_failure "Google Gemini Location:\t\t" "$1" "gemini.google.com"
        return
    fi
    local region=$(echo "$tmp" | grep K4WWud | json_query .[0][2] | grep -Eo '\[\[\\"(.*)\\",\\"S' )
    echo -n -e "\r Google Gemini Location:\t\t${Font_Yellow}$(trim_chars "$region" 4 6)${Font_Suffix}\n"
}

function AIUnlockTest_Copilot() {
    local tmp=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://copilot.microsoft.com/" 2>&1)
    local tmp2=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://copilot.microsoft.com/turing/conversation/chats?bundleVersion=1.1342.3-cplt.12"  2>&1)
    if [[ "$tmp" == "curl"* ]]; then
        print_network_failure "Microsoft Copilot:\t\t\t" "$1" "copilot.microsoft.com"
        return
    fi
    local result=$(echo "$tmp2" | json_query .result.value  2>&1 | tr -d '"' 2>&1) 
    local region=$(echo "$tmp" | sed -n 's/.*RevIpCC:"\([^"]*\)".*/\1/p' )
    if [[ "$result" == "Success" ]];then
        echo -n -e "\r Microsoft Copilot:\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
    else 
        echo -n -e "\r Microsoft Copilot:\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
    fi
}

function AIUnlockTest_Claude(){
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s -o /dev/null -L --max-time 10 -w '%{url_effective}%{http_code}\n' "https://claude.ai/" 2>&1)
    if [[ "$result" == *"000" ]]; then
        print_network_failure "Claude:\t\t\t\t" "$1" "claude.ai"
        return
    fi

    if [[ "$result" == *unavailable* ]]; then
        echo -n -e "\r Claude:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Claude:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    print_network_failure "Claude:\t\t\t\t" "$1" "claude.ai"
    return
}

function MediaUnlockTest_RakutenMagazine() {
    local result=$(curl $curlArgs -${1} -sL --write-out %{http_code} --output /dev/null --max-time 10 "https://data-cloudauthoring.magazine.rakuten.co.jp/rem_repository/////////.key" 2>&1)

    if [[ "$result" == "000" ]]; then
        print_network_failure "Rakuten MAGAZINE:\t\t\t" "$1" "data-cloudauthoring.magazine.rakuten.co.jp"
        return
    elif [[ "$result" == "403" ]]; then
        echo -n -e "\r Rakuten MAGAZINE:\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$result" == "404" ]]; then
        echo -n -e "\r Rakuten MAGAZINE:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r Rakuten MAGAZINE:\t\t\t${Font_Red}Failed ($result)${Font_Suffix}\n"
    return

}

function MediaUnlockTest_AnimeFesta() {
    local result1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsLI -X GET --write-out %{http_code} --output /dev/null --max-time 10 "https://api-animefesta.iowl.jp/v1/titles/1" -H 'x-requested-with: XMLHttpRequest'  2>&1)
    if [[ "$result1" == "000" ]]; then
        print_network_failure "AnimeFesta:\t\t\t\t" "$1" "api-animefesta.iowl.jp"
        return
    fi
    if [[ "$result1" == "200" ]]; then
        echo -n -e "\r AnimeFesta:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result1" == "403" ]]; then
        echo -n -e "\r AnimeFesta:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r AnimeFesta:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_Lemino() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 -X POST 'https://if.lemino.docomo.ne.jp/v1/user/delivery/watch/ready'  2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "Lemino:\t\t\t\t" "$1" "if.lemino.docomo.ne.jp"
        return
    fi
    if [[ "$tmpresult" == *"CloudFront"* ]]; then
        echo -n -e "\r Lemino:\t\t\t\t${Font_Red}No  (Blocked)${Font_Suffix}\n"
        return
    fi
    result=$(echo $tmpresult | json_query .result_code | tr -d '"')
    if [[ "$result" != "null" ]]; then
        if [[ "$result" == "WEBW100100" ]]; then
            echo -n -e "\r Lemino:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
            return
        elif [[ "$result" == "WEBW300100" ]]; then
            echo -n -e "\r Lemino:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
            return
        else
            echo -n -e "\r Lemino:\t\t\t\t${Font_Red}Unknown (Code: $result)${Font_Suffix}\n"
            return
        fi
    else
        echo -n -e "\r Lemino:\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_mora() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 'https://mora.jp/buy?__requestToken=1713764407153&returnUrl=https%3A%2F%2Fmora.jp%2Fpackage%2F43000087%2FTFDS01006B00Z%2F%3Ffmid%3DTOPRNKS%26trackMaterialNo%3D31168909&fromMoraUx=false&deleteMaterial=' -H 'host: mora.jp' 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "Mora:\t\t\t\t\t" "$1" "mora.jp"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r Mora:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "500" ]; then
        echo -n -e "\r Mora:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Mora:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_DAnimeStore(){
    # The redirect target decides the result. It can be an HTTP redirect or a meta
    # refresh in the page, so headers (-i) and body of every hop are searched.
    # The docomo ID host is reached first, and OpenSSL 3 refuses its TLS (legacy
    # renegotiation), so curl may stop there: it is checked before any curl error.
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSLi --max-time 10 'https://animestore.docomo.ne.jp/animestore/reg_pc' 2>&1)
    if [[ "$tmpresult" == *"animestore/CF/overseas_warn"* ]]; then
        echo -n -e "\r D Anime Store:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    elif [[ "$tmpresult" == *"id.smt.docomo.ne.jp/cgi8/oidc/authorize"* || "$tmpresult" == *"cfg.smt.docomo.ne.jp/authx/cgi/baseauth"* ]]; then
        echo -n -e "\r D Anime Store:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ -z "$tmpresult" || "$tmpresult" == *"curl: ("* ]]; then
        debug_log "$tmpresult"
        print_network_failure "D Anime Store:\t\t\t\t" "$1" "animestore.docomo.ne.jp"
        return
    fi
    debug_log "$tmpresult"
    echo -n -e "\r D Anime Store:\t\t\t\t${Font_Red}No  (Blocked by WAF)${Font_Suffix}\n"
}

function MediaUnlockTest_EroGameSpace(){
    local tmpresult=$(curl $usePROXY $xForward -${1} -sSL --max-time 3  "https://erogamescape.org" 2>&1)
    # The site silently drops unsupported IPs, so a timeout (curl exit 28) means No.
    if [[ "$tmpresult" == "curl"* && "$tmpresult" != "curl: (28)"* ]]; then
        print_network_failure "EroGameSpace:\t\t\t\t" "$1" "erogamescape.org"
        return
    fi

    local result=$(echo "$tmpresult" | grep '18歳')
    if [ -n "$result" ]; then
      echo -n -e "\r EroGameSpace:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ -z "$countrycode" ]; then
        echo -n -e "\r EroGameSpace:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_RakutenTVJP(){
    local tmpresult=$(curl $curlArgs -${1} -sSL --max-time 10 'https://api.tv.rakuten.co.jp/content/playinfo.json?content_id=1&device_id=1' 2>&1)
    if [[ "$tmpresult" = "curl"* ]]; then
        print_network_failure "Rakuten TV JP:\t\t\t\t" "$1" "api.tv.rakuten.co.jp"
        return
    fi

    local result=$(echo $tmpresult | json_query .result.code | tr -d '"')
    if [[ "$result" == "40404030802" ]]; then
        echo -n -e "\r Rakuten TV JP:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [[ "$result" == "40301720109" ]]; then
        echo -n -e "\r Rakuten TV JP:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r Rakuten TV JP:\t\t\t\t${Font_Red}Unknown (Code: $result)${Font_Suffix}\n"
        return
    fi
}

function MediaUnlockTest_ofiii() {
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://cdi.ofiii.com/ofiii_cdi/video/urls?device_type=pc&device_id=450b705c-7a08-49e9-9297-10ec0c8624b0&media_type=comic&asset_id=vod68157-020015M001&project_num=OFWEB00&puid=7a9c18b9-eecc-499b-afd2-e905bf04f5a4" 2>&1)
    if [[ "$result" == "000" ]]; then
        print_network_failure "ofiii:\t\t\t\t\t" "$1" "cdi.ofiii.com"
        return
    fi
    if [[ "$result" == "200" ]]; then
        echo -n -e "\r ofiii:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    else
        echo -n -e "\r ofiii:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi

    echo -n -e "\r ofiii:\t\t\t\t\t${Font_Red}Failed${Font_Suffix}\n"
}

function MediaUnlockTest_DStv() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://now.dstv.com/" 2>&1)
    if [ "$result" = "000" ]; then
        print_network_failure "DStv:\t\t\t\t\t" "$1" "now.dstv.com"
        return
    elif [ "$result" = "200" ]; then
        echo -n -e "\r DStv:\t\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    elif [ "$result" = "451" ]; then
        echo -n -e "\r DStv:\t\t\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    else
        echo -n -e "\r DStv:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
        return
    fi

}

function MediaUnlockTest_beIN_Sports() {
    local result=$(curl $curlArgs -${1} -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://d6m3sfa7e58z5.cloudfront.net/out/v1/3b0660e05eed4d769521eb0275aab3ab/index.mpd")
    if [ "$result" = "000" ]; then
        print_network_failure "beIN Sports:\t\t\t\t" "$1" "d6m3sfa7e58z5.cloudfront.net"
    elif [ "$result" = "200" ]; then
        echo -n -e "\r beIN Sports:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
    elif [ "$result" = "403" ]; then
        echo -n -e "\r beIN Sports:\t\t\t\t${Font_Red}No${Font_Suffix}\n"
    else
        echo -n -e "\r beIN Sports:\t\t\t\t${Font_Red}Failed (Unexpected Result: $result)${Font_Suffix}\n"
    fi
}

function MediaUnlockTest_Wikipedia_Editable(){
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -w '\n%{http_code}' 'https://zh.wikipedia.org/w/index.php?title=Wikipedia%3A%E6%B2%99%E7%9B%92&action=edit' 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Wikipedia Editability:\t\t\t" "$1" "zh.wikipedia.org"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    if [[ "$tmpresult" == *"Banned"* ]]; then
        echo -n -e "\r Wikipedia Editability:\t\t\t${Font_Red}No${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" == "200" ]]; then
        echo -n -e "\r Wikipedia Editability:\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" == "429" ]]; then
        echo -n -e "\r Wikipedia Editability:\t\t\t${Font_Yellow}Rate Limited${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Wikipedia Editability:\t\t\t${Font_Red}Failed (Unexpected Result: ${httpcode})${Font_Suffix}\n"
}

function MediaUnlockTest_BingSearch() {
    # A cookie jar is needed: bing.com first redirects to /?brdr=1 and expects the cookie back.
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL -b "" --max-time 10 -w '\n%{http_code}' "https://www.bing.com" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Bing:\t\t\t\t\t" "$1" "www.bing.com"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    local risky=""
    if [[ "$tmpresult" == *'sj_cook.set("SRCHHPGUSR","HV"'* ]]; then
        risky=" [Risky]"
    fi
    local region=""
    if [[ "$httpcode" == "200" ]]; then
        region=$(echo "$tmpresult" | grep -Eo 'Region:"[^"]*"' | head -n1 | cut -d'"' -f2)
    fi
    if [[ "$region" == "CN" || -z "$region" ]] && [[ "$tmpresult" == *"cn.bing.com"* ]]; then
        echo -n -e "\r Bing:\t\t\t\t\t${Font_Yellow}Only cn.bing.com (Region: CN)${risky}${Font_Suffix}\n"
        return
    fi
    if [ -n "$region" ]; then
        if [ -n "$risky" ]; then
            echo -n -e "\r Bing:\t\t\t\t\t${Font_Yellow}Yes (Region: $(to_upper "$region"))${risky}${Font_Suffix}\n"
        else
            echo -n -e "\r Bing:\t\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
        fi
        return
    fi
    if [[ "$httpcode" == "403" ]] || [[ "$httpcode" == "451" ]]; then
        echo -n -e "\r Bing:\t\t\t\t\t${Font_Red}No  (Banned)${risky}${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Bing:\t\t\t\t\t${Font_Red}Failed (Unexpected Result: ${httpcode})${Font_Suffix}\n"
}

function MediaUnlockTest_Microsoft() {
    # MSN Weather embeds the IP-detected location (same one Bing shows for "weather") in its page state.
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 -H 'accept-language: en-US,en;q=0.9' "https://www.msn.com/en-us/weather/forecast" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Microsoft Location:\t\t\t" "$1" "www.msn.com"
        return
    fi
    local location=$(echo "$tmpresult" | grep -o '"currentLocation":{[^}]*"isDetected":true[^}]*}' | head -n1 | grep -o '"displayName":"[^"]*"' | cut -d'"' -f4)
    if [ -z "$location" ]; then
        echo -n -e "\r Microsoft Location:\t\t\t${Font_Red}Failed (Unknown)${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Microsoft Location:\t\t\t${Font_Green}${location}${Font_Suffix}\n"
}

function MediaUnlockTest_Reddit() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -w '\n%{http_code}' "https://www.reddit.com/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Reddit:\t\t\t\t" "$1" "www.reddit.com"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    if [[ "$httpcode" == "429" ]]; then
        echo -n -e "\r Reddit:\t\t\t\t${Font_Yellow}Rate Limited${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" == "200" ]] || [[ "$httpcode" == "302" ]]; then
        echo -n -e "\r Reddit:\t\t\t\t${Font_Green}Yes${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" == "403" ]] && [[ "$tmpresult" == *"been blocked"* ]]; then
        echo -n -e "\r Reddit:\t\t\t\t${Font_Red}No  (Blocked)${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Reddit:\t\t\t\t${Font_Red}Failed (Unexpected Result: ${httpcode})${Font_Suffix}\n"
}

function MediaUnlockTest_X() {
    local trace=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -w '\n%{http_code}' "https://x.com/cdn-cgi/trace" 2>&1)
    if [[ "$trace" == "curl"* ]]; then
        print_network_failure "X (formerly Twitter):\t\t\t" "$1" "x.com"
        return
    fi
    local tracecode=${trace##*$'\n'}
    local region=$(echo "$trace" | grep '^loc=' | cut -d= -f2 | tr -d '\r')
    if [[ "$tracecode" == "429" ]]; then
        echo -n -e "\r X (formerly Twitter):\t\t\t${Font_Yellow}Rate Limited${Font_Suffix}\n"
        return
    fi
    if [[ "$tracecode" != "200" ]] || [ -z "$region" ]; then
        echo -n -e "\r X (formerly Twitter):\t\t\t${Font_Red}Failed (Unknown Region)${Font_Suffix}\n"
        return
    fi
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -w '\n%{http_code}' "https://x.com/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "X (formerly Twitter):\t\t\t" "$1" "x.com"
        return
    fi
    local httpcode=${tmpresult##*$'\n'}
    if [[ "$httpcode" == "429" ]]; then
        echo -n -e "\r X (formerly Twitter):\t\t\t${Font_Yellow}Rate Limited (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" == "403" ]] || [[ "$httpcode" == "451" ]] || [[ " CN IR MM KP RU TM " == *" $(to_upper "$region") "* ]]; then
        echo -n -e "\r X (formerly Twitter):\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    fi
    if echo "$tmpresult" | grep -qiE 'attention required|cf-chl|checking your browser|just a moment|access denied|request blocked|unusual traffic'; then
        echo -n -e "\r X (formerly Twitter):\t\t\t${Font_Red}No  (Banned by WAF)${Font_Suffix}\n"
        return
    fi
    if [[ "$httpcode" -lt 200 ]] || [[ "$httpcode" -ge 400 ]]; then
        echo -n -e "\r X (formerly Twitter):\t\t\t${Font_Red}Failed (Unexpected Result: ${httpcode})${Font_Suffix}\n"
        return
    fi
    if [[ "$region" == "T1" ]]; then
        region="Tor"
    fi
    echo -n -e "\r X (formerly Twitter):\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
}

function MediaUnlockTest_Apple() {
    local region=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 "https://gspe1-ssl.ls.apple.com/pep/gcc" 2>&1)
    if [[ "$region" == "curl"* ]]; then
        print_network_failure "Apple:\t\t\t\t\t" "$1" "gspe1-ssl.ls.apple.com"
        return
    fi
    region=$(echo "$region" | tr -d ' \t\n\r\v\f')
    if ! [[ "$region" =~ ^[A-Za-z]{2}$ ]]; then
        echo -n -e "\r Apple:\t\t\t\t\t${Font_Red}Failed (Unexpected Result)${Font_Suffix}\n"
        return
    fi
    local supported=" AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IS IT JE JM JO JP KE KG KH KI KM KN KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW "
    if [[ "$supported" == *" $(to_upper "$region") "* ]]; then
        echo -n -e "\r Apple:\t\t\t\t\t${Font_Green}Yes (Region: $(to_upper "$region"))${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Apple:\t\t\t\t\t${Font_Red}No  (Region: $(to_upper "$region"))${Font_Suffix}\n"
}

function MediaUnlockTest_Facebook() {
    local cookiejar=$(mktemp)
    local fbArgs=(--user-agent "${UA_Browser}" -sS --max-time 10 -b "$cookiejar" -c "$cookiejar" -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' -H 'accept-language: en-US,en;q=0.9' -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' -H 'sec-fetch-site: none' -H 'sec-fetch-user: ?1' -H 'upgrade-insecure-requests: 1')
    local tmpresult=$(curl $curlArgs -${1} "${fbArgs[@]}" "https://www.facebook.com/ads/library/" 2>&1)
    if [[ "$tmpresult" == "curl"* ]]; then
        rm -f "$cookiejar"
        print_network_failure "Facebook:\t\t\t\t" "$1" "www.facebook.com"
        return
    fi
    # The first visit may return a JS challenge that POSTs to a verify URL and reloads.
    local verify=$(echo "$tmpresult" | grep -o "/__rd_verify_[^'\"]*" | head -n1)
    if [ -n "$verify" ]; then
        curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -b "$cookiejar" -c "$cookiejar" -X POST -o /dev/null "https://www.facebook.com${verify}" 2>/dev/null
        tmpresult=$(curl $curlArgs -${1} "${fbArgs[@]}" -L "https://www.facebook.com/ads/library/" 2>&1)
    fi
    rm -f "$cookiejar"
    if [[ "$tmpresult" == "curl"* ]]; then
        print_network_failure "Facebook:\t\t\t\t" "$1" "www.facebook.com"
        return
    fi
    local region=$(echo "$tmpresult" | grep -o '"AdsCurrentUser",\[\],{[^}]*"countryCode":"[A-Z]\{2\}"' | grep -o '"countryCode":"[A-Z]\{2\}"' | head -n1 | cut -d'"' -f4)
    if [ -z "$region" ]; then
        region=$(echo "$tmpresult" | grep -o '"defaultCountry":"[A-Z]\{2\}"' | head -n1 | cut -d'"' -f4)
    fi
    if [ -n "$region" ]; then
        echo -n -e "\r Facebook:\t\t\t\t${Font_Green}Yes (Region: ${region})${Font_Suffix}\n"
        return
    fi
    echo -n -e "\r Facebook:\t\t\t\t${Font_Red}Failed (Unknown Region)${Font_Suffix}\n"
}


function echo_Result() {
    for((i=0;i<${#array[@]};i++))
    do
        echo "$result" | grep "${array[i]}"
        # sleep 0.03
    done;
}

if [ -n "$func" ]; then
    echo -e "${Font_Green}IPv4:${Font_Suffix}"
    run_check $func 4
    echo -e "${Font_Green}IPv6:${Font_Suffix}"
    run_check $func 6
    exit
fi

function NA_UnlockTest() {
    echo "===========[ North America ]==========="
    local result=$(
    run_check MediaUnlockTest_Fox ${1} &
    run_check MediaUnlockTest_HuluUS ${1} &
    run_check MediaUnlockTest_NFLPlus ${1} &
    run_check MediaUnlockTest_ESPNPlus ${1} &
    run_check MediaUnlockTest_EPIX ${1} &
    run_check MediaUnlockTest_Starz ${1} &
    run_check MediaUnlockTest_Philo ${1} &
    run_check MediaUnlockTest_FXNOW ${1} &
    run_check MediaUnlockTest_HBOMax ${1} &
    # MediaUnlockTest_TLCGO ${1} & # Wait to fix.
    )
    wait
    local array=("FOX:" "Hulu:" "NFL+" "ESPN+:" "MGM+:" "Starz:" "Philo:" "FXNOW:" "HBO Max")
    echo_Result ${result} ${array}
    local result=$(
    run_check MediaUnlockTest_Shudder ${1} &
    run_check MediaUnlockTest_BritBox ${1} &
    run_check MediaUnlockTest_CWTV ${1} &
    run_check MediaUnlockTest_AETV ${1} &
    run_check MediaUnlockTest_NBATV ${1} &
    run_check MediaUnlockTest_FuboTV ${1} &
    run_check MediaUnlockTest_TubiTV ${1} &
    )
    wait
    local array=("Shudder:" "BritBox:" "CW TV:" "A&E TV:" "NBA TV:")
    echo_Result ${result} ${array}
    run_check MediaUnlockTest_NBCTV ${1}
    echo "$result" | grep "Fubo TV:"
    echo "$result" | grep "Tubi TV:"
    local result=$(
    run_check MediaUnlockTest_SlingTV ${1} &
    run_check MediaUnlockTest_PlutoTV ${1} &
    run_check MediaUnlockTest_AcornTV ${1} &
    run_check MediaUnlockTest_SHOWTIME ${1} &
    run_check MediaUnlockTest_encoreTVB ${1} &
    run_check MediaUnlockTest_DiscoveryPlus ${1} &
    run_check MediaUnlockTest_ParamountPlus ${1} &
    run_check MediaUnlockTest_PeacockTV ${1} &
    run_check MediaUnlockTest_Popcornflix ${1} &
    run_check MediaUnlockTest_Crunchyroll ${1} &
    run_check MediaUnlockTest_ATTNOW ${1} &
    # MediaUnlockTest_KBSAmerican ${1} &
    run_check MediaUnlockTest_KOCOWA ${1} &
    # MediaUnlockTest_MathsSpot ${1} &
    )
    wait
    local array=("Sling TV:" "Pluto TV:" "Acorn TV:" "SHOWTIME:" "encoreTVB:" "Discovery" "Paramount+:" "Peacock TV:" "Popcornflix:" "Crunchyroll:" "Directv Stream:" "KBS American:" "KOCOWA:" "Maths Spot:")
    echo_Result ${result} ${array}
    ShowRegion CA
    local result=$(
    run_check MediaUnlockTest_HotStar ${1} &
    run_check MediaUnlockTest_CBCGem ${1} &
    run_check MediaUnlockTest_Crave ${1} &
    )
    wait
    echo "$result" | grep "HotStar:"
    echo "$result" | grep "CBC Gem:"
    echo "$result" | grep "Crave:"
    echo "======================================="
}

function EU_UnlockTest() {
    echo "===============[ Europe ]=============="
    local result=$(
    run_check MediaUnlockTest_RakutenTV ${1} &
    run_check MediaUnlockTest_SkyShowTime ${1} &
    # MediaUnlockTest_MathsSpot ${1} &
    run_check MediaUnlockTest_Eurosport ${1} &
    run_check MediaUnlockTest_Viaplay ${1} &
    run_check MediaUnlockTest_SetantaSports ${1} &
    # MediaUnlockTest_HBO_Nordic ${1}
    # MediaUnlockTest_HBOGO_EUROPE ${1}
    )
    wait
    local array=("Rakuten TV:" "SkyShowTime:" "HBO Max:" "Maths Spot:" "Viaplay" "Eurosport" "Setanta Sports:")
    echo_Result ${result} ${array}
    ShowRegion GB
    local result=$(
    run_check MediaUnlockTest_HotStar ${1} &
    run_check MediaUnlockTest_SkyGo ${1} &
    run_check MediaUnlockTest_BritBox ${1} &
    run_check MediaUnlockTest_ITVHUB ${1} &
    run_check MediaUnlockTest_Channel4 ${1} &
    run_check MediaUnlockTest_Channel5 ${1} &
    run_check MediaUnlockTest_BBCiPLAYER ${1} &
    run_check MediaUnlockTest_DiscoveryPlusUK ${1} &
    )
    wait
    local array=("HotStar:" "Sky Go:" "BritBox:" "ITV Hub:" "Channel 4:" "Channel 5" "BBC iPLAYER:" "Discovery+ UK:")
    echo_Result ${result} ${array}
    ShowRegion FR
    local result=$(
    #MediaUnlockTest_Salto ${1} &
    run_check MediaUnlockTest_CanalPlus ${1} &
    run_check MediaUnlockTest_Molotov ${1} &
    run_check MediaUnlockTest_FranceTV ${1} &
    run_check MediaUnlockTest_Joyn ${1} &
    run_check MediaUnlockTest_SKY_DE ${1} &
    run_check MediaUnlockTest_ZDF ${1} &
    )
    wait
    local array=("Canal+:" "Molotov:" "France.tv")
    echo_Result ${result} ${array}
    ShowRegion DE
    local array=("Joyn:" "Sky DE:" "ZDF:")
    echo_Result ${result} ${array}
    ShowRegion NL
    local result=$(
    run_check MediaUnlockTest_videoland ${1} &
    run_check MediaUnlockTest_NPO_Start_Plus ${1} &
    # MediaUnlockTest_HBO_Spain ${1}
    run_check MediaUnlockTest_MoviStarPlus ${1} &
    run_check MediaUnlockTest_RaiPlay ${1} &
    run_check MediaUnlockTest_Sky_CH ${1} &
    #MediaUnlockTest_MegogoTV ${1}
    run_check MediaUnlockTest_Amediateka ${1} &
    )
    wait
    local array=("videoland:" "NPO Start Plus:")
    echo_Result ${result} ${array}
    ShowRegion ES
    echo "$result" | grep "Movistar+:"
    ShowRegion IT
    echo "$result" | grep "Rai Play:"
    ShowRegion CH
    echo "$result" | grep "SKY CH:"
    ShowRegion RU
    echo "$result" | grep "Amediateka:"
    echo "======================================="
}

function HK_UnlockTest() {
    echo "=============[ Hong Kong ]============="
	local result=$(
	    run_check MediaUnlockTest_NowTV ${1} &
	    run_check MediaUnlockTest_ViuTV ${1} &
	    run_check MediaUnlockTest_Viu.com ${1} &
	    run_check MediaUnlockTest_MyTVSuper ${1} &
	    # MediaUnlockTest_HBOGO_ASIA ${1} &
        run_check MediaUnlockTest_HBOMax ${1} &
        run_check MediaUnlockTest_HoyTV ${1} &
        run_check MediaUnlockTest_BahamutAnime ${1} &
        run_check MediaUnlockTest_NBATV ${1} &
	    # MediaUnlockTest_BilibiliHKMCTW ${1} &
	)
    wait
    local array=("Now TV:" "Viu.TV:" "Viu.com:" "MyTVSuper:" "HBO Max:" "HOY TV" "BiliBili Hongkong/Macau/Taiwan:" "Bahamut Anime:" "NBA TV:")
    echo_Result ${result} ${array}
    echo "======================================="
}

function TW_UnlockTest() {
    echo "==============[ Taiwan ]==============="
    local result=$(
    run_check MediaUnlockTest_KKTV ${1} &
    run_check MediaUnlockTest_LiTV ${1} &
    run_check MediaUnlockTest_MyVideo ${1} &
    #MediaUnlockTest_4GTV ${1} &
    run_check MediaUnlockTest_LineTV.TW ${1} &
    run_check MediaUnlockTest_HamiVideo ${1} &
    run_check MediaUnlockTest_Catchplay ${1} &
    # MediaUnlockTest_HBOGO_ASIA ${1} &
    run_check MediaUnlockTest_HBOMax ${1} &
    run_check MediaUnlockTest_BahamutAnime ${1} &
    run_check MediaUnlockTest_FridayVideo ${1} &
    run_check MediaUnlockTest_ofiii ${1} &
    #MediaUnlockTest_ElevenSportsTW ${1}
    # MediaUnlockTest_BilibiliTW ${1} &
    )
    wait
    local array=("KKTV:" "LiTV:" "ofiii:" "MyVideo:" "4GTV.TV:" "LineTV.TW:" "Hami Video:" "CatchPlay+:" "HBO Max" "Bahamut Anime:" "Friday Video:" "Bilibili Taiwan Only:")
    echo_Result ${result} ${array}
    echo "======================================="
}

function JP_UnlockTest() {
    echo "===============[ Japan ]==============="
    local result=$(
    run_check MediaUnlockTest_NHKPlus ${1} &
    run_check MediaUnlockTest_DMMTV ${1} &
    run_check MediaUnlockTest_AbemaTV_IPTest ${1} &
    run_check MediaUnlockTest_Niconico ${1} &
    run_check MediaUnlockTest_Telasa ${1} &
    run_check MediaUnlockTest_unext ${1} &
    run_check MediaUnlockTest_HuluJP ${1} &
    )
    wait
    local array=("NHK+" "DMM TV:" "Abema.TV:" "Niconico:" "Telasa:" "U-NEXT:" "Hulu Japan:")
    echo_Result ${result} ${array}
    local result=$(
    run_check MediaUnlockTest_TVer ${1} &
    run_check MediaUnlockTest_wowow ${1} &
    run_check MediaUnlockTest_VideoMarket ${1} &
    run_check MediaUnlockTest_DAnimeStore ${1} &
    run_check MediaUnlockTest_FOD ${1} &
    run_check MediaUnlockTest_Radiko ${1} &
    run_check MediaUnlockTest_DAM ${1} &
    run_check MediaUnlockTest_AnimeFesta ${1} &
    run_check MediaUnlockTest_Lemino ${1} &
    run_check MediaUnlockTest_J:COM_ON_DEMAND ${1} &
    run_check MediaUnlockTest_RakutenTVJP ${1} &
    run_check MediaUnlockTest_MGStage ${1} &
    )
    wait
    local array=("TVer:" "WOWOW:" "VideoMarket:" "D Anime Store:" "FOD(Fuji TV):" "Radiko:" "Karaoke@DAM:" "J:com On Demand:" "AnimeFesta:" "Lemino:" "MGStage:" "Rakuten TV JP:")
    echo_Result ${result} ${array}
    ShowRegion Game
    local result=$(
    run_check MediaUnlockTest_Kancolle ${1} &
    run_check MediaUnlockTest_UMAJP ${1} &
    run_check MediaUnlockTest_PCRJP ${1} &
    run_check MediaUnlockTest_ProjectSekai ${1} &
    )
    wait
    local array=("Kancolle Japan:" "Pretty Derby Japan:" "Princess Connect Re:Dive Japan:" "World Flipper Japan:" "Project Sekai: Colorful Stage:")
    echo_Result ${result} ${array}
    ShowRegion Read
    local result=$(
    run_check MediaUnlockTest_RakutenMagazine ${1} &
    )
    wait
    local array=("Rakuten MAGAZINE")
    echo_Result ${result} ${array}
    ShowRegion Music
    local result=$(
    run_check MediaUnlockTest_mora ${1} &
    run_check MediaUnlockTest_music.jp ${1} &
    )
    wait
    local array=("Mora:" "music.jp:") 
    echo_Result ${result} ${array}
    ShowRegion Forum
    run_check MediaUnlockTest_EroGameSpace ${1}
    echo "======================================="

}

function Global_UnlockTest() {
    echo ""
    echo "============[ Multination ]============"
    local result=$(
    run_check MediaUnlockTest_Dazn ${1} &
    run_check MediaUnlockTest_DisneyPlus ${1} &
    run_check MediaUnlockTest_Netflix ${1} &
    run_check MediaUnlockTest_YouTube_Premium ${1} &
    run_check MediaUnlockTest_PrimeVideo_Region ${1} &
    run_check MediaUnlockTest_TVBAnywhere ${1} &
    run_check MediaUnlockTest_iQYI_Region ${1} &
    run_check MediaUnlockTest_YouTube_CDN ${1} &
    run_check MediaUnlockTest_NetflixCDN ${1} &
    run_check MediaUnlockTest_Wikipedia_Editable ${1} &
    run_check MediaUnlockTest_BingSearch ${1} &
    run_check MediaUnlockTest_Microsoft ${1} &
    run_check MediaUnlockTest_Reddit ${1} &
    run_check MediaUnlockTest_X ${1} &
    run_check MediaUnlockTest_Apple ${1} &
    run_check MediaUnlockTest_Facebook ${1} &
    run_check MediaUnlockTest_Spotify ${1} &
    # MediaUnlockTest_Instagram.Music ${1}
    run_check GameTest_Steam ${1} &
    run_check MediaUnlockTest_Google ${1} &
	  run_check WebTest_GoogleSearchCAPTCHA ${1} &
    run_check MediaUnlockTest_GooglePlayStore ${1} &
    run_check MediaUnlockTest_GoogleGemini ${1} &
    run_check MediaUnlockTest_Tiktok ${1} &
    run_check MediaUnlockTest_BilibiliAnimeNew ${1} &
    )
    wait
    local array=("Dazn:" "Disney+:" "Netflix:" "YouTube Premium:" "Amazon Prime Video:" "TVBAnywhere+:" "iQyi Oversea:" "Bilibili Anime:" "Tiktok" "YouTube CDN:" "Google Location:" "Google Search CAPTCHA Free:" "Google Play Store:" "Google Gemini:" "YouTube Region:" "Netflix Preferred CDN:" "Wikipedia" "Bing:" "Microsoft Location:" "Reddit:" "X (formerly Twitter):" "Apple:" "Facebook:" "Spotify" "Steam Currency:" "Instagram")
	  echo_Result ${result} ${array}
    echo "======================================="
}

function SA_UnlockTest() {
    echo "===========[ South America ]==========="
    local result=$(
    run_check MediaUnlockTest_DirecTVGO ${1} &
    )
    wait
    local array=("Star+:" "HBO Max:" "DirecTV Go:")
    echo_Result ${result} ${array}
    echo "======================================="
}

function OA_UnlockTest() {
    echo "==============[ Oceania ]=============="
    local result=$(
    run_check MediaUnlockTest_Viu.com ${1} &
    run_check MediaUnlockTest_NBATV ${1} &
    run_check MediaUnlockTest_AcornTV ${1} &
    run_check MediaUnlockTest_SHOWTIME ${1} &
    run_check MediaUnlockTest_BritBox ${1} &
    run_check MediaUnlockTest_ParamountPlus ${1} &
    )
    wait
    local array=("Viu.com:" "NBA TV:" "Acorn TV:" "SHOWTIME:" "BritBox:" "Paramount+:")
    echo_Result ${result} ${array}
    ShowRegion AU
    local result=$(
    run_check MediaUnlockTest_Stan ${1} &
    run_check MediaUnlockTest_Binge ${1} &
    run_check MediaUnlockTest_7plus ${1} &
    run_check MediaUnlockTest_Channel9 ${1} &
    run_check MediaUnlockTest_Channel10 ${1} &
    run_check MediaUnlockTest_ABCiView ${1} &
    run_check MediaUnlockTest_OptusSports ${1} &
    run_check MediaUnlockTest_SBSonDemand ${1} &
    run_check MediaUnlockTest_Docplay ${1}
    run_check MediaUnlockTest_KayoSports ${1}
    )
    wait
    local array=("Stan:" "Binge:" "7plus:" "Channel 9:" "Channel 10:" "ABC iView:" "Docplay:" "Optus Sports:" "SBS on Demand:" "Kayo Sports:")
    echo_Result ${result} ${array}
    ShowRegion NZ
    local result=$(
    run_check MediaUnlockTest_NeonTV ${1} &
    run_check MediaUnlockTest_SkyGONZ ${1} &
    run_check MediaUnlockTest_ThreeNow ${1} &
    run_check MediaUnlockTest_MaoriTV ${1} &
    )
    wait
    local array=("Neon TV:" "SkyGo NZ:" "ThreeNow:" "Maori TV:")
    echo_Result ${result} ${array}
    echo "======================================="
}

function KR_UnlockTest() {
    echo "==============[ Korean ]==============="
    local result=$(
    run_check MediaUnlockTest_Wavve ${1} &
    run_check MediaUnlockTest_Tving ${1} &
    run_check MediaUnlockTest_CoupangPlay ${1} &
    run_check MediaUnlockTest_NaverTV ${1} &
    run_check MediaUnlockTest_Afreeca ${1} &
    # MediaUnlockTest_SpotvNow ${1} &
    run_check MediaUnlockTest_KBSDomestic ${1} &
    run_check MediaUnlockTest_PandaTV ${1} &
    run_check MediaUnlockTest_KOCOWA ${1} &
    )
    wait
    local array=("Wavve:" "Tving:" "Coupang Play:" "Naver TV:" "Afreeca TV:" "SPOTV NOW:" "KBS Domestic:" "PandaTV:")
    echo_Result ${result} ${array}
    echo "======================================="
}

function Asia_UnlockTest(){
    echo "================[ Asia ]==============="
    local result=$(
    # MediaUnlockTest_HBOGO_ASIA ${1} &
    run_check MediaUnlockTest_HotStar ${1} &
    run_check MediaUnlockTest_Viu.com ${1} &
    run_check MediaUnlockTest_HBOMax ${1} &
    MediaUnblockTest_BGlobalSEA ${1} &
    )
    wait
    local array=("HotStar:" "Viu.com:" "HBO Max:" "B-Global SouthEastAsia:")
    echo_Result ${result} ${array}
    ShowRegion SG
    local result=$(
        run_check MediaUnlockTest_Catchplay ${1} &
        run_check MediaUnlockTest_meWATCH ${1} &
        run_check MediaUnlockTest_StarhubTVPlus ${1} &
    )
    wait
    local array=("meWATCH" "Starhub" "CatchPlay+:")
    echo_Result ${result} ${array}
    ShowRegion TH
    local result=$(
    #MediaUnlockTest_TrueID ${1} &
    run_check MediaUnlockTest_AISPlay ${1} &
    MediaUnblockTest_BGlobalTH ${1} &
    )
    wait
    local array=("TrueID" "AIS Play" "B-Global Thailand Only")
    echo_Result ${result} ${array}
    ShowRegion ID
    local result=$(
    run_check MediaUnlockTest_Vidio ${1} &
    run_check MediaUnlockTest_beIN_Sports ${1} &
    MediaUnblockTest_BGlobalID ${1} &
    )
    wait
    local array=("Vidio" "beIN Sports" "B-Global Indonesia Only")
    echo_Result ${result} ${array}
    ShowRegion VN
    local result=$(
    # MediaUnlockTest_VTVcab ${1} &
    run_check MediaUnlockTest_MYTV ${1} &
    run_check MediaUnlockTest_ClipTV ${1} &
    run_check MediaUnlockTest_GalaxyPlay ${1} &
    run_check MediaUnlockTest_KPlus ${1} &
    #MediaUnlockTest_TV360 ${1} &
    MediaUnblockTest_BGlobalVN ${1} &
    )
    wait
    local array=("MYTV" "Clip TV" "Galaxy Play" "K+" "TV360" "B-Global Việt Nam Only" )
    echo_Result ${result} ${array}
    ShowRegion MY
    local result=$(
    run_check MediaUnlockTest_Sooka ${1} &
    )
    wait
    local array=("Sooka")
    echo_Result ${result} ${array}
    ShowRegion IN
    local result=$(
    run_check MediaUnlockTest_MXPlayer ${1} &
    run_check MediaUnlockTest_TataPlay ${1} &
    run_check MediaUnlockTest_SonyLiv ${1} &
    run_check MediaUnlockTest_JioCinema ${1} &
    run_check MediaUnlockTest_Zee5 ${1} &
    run_check MediaUnlockTest_NBATV ${1} &
    )
    wait
    local array=("Zee5:" "NBA TV:" "MXPlayer" "Tata Play" "SonyLiv" "Jio Cinema")
    echo_Result ${result} ${array}
    echo "======================================="
}

function AF_UnlockTest() {
    echo "==============[ Africa ]=============="
    local result=$(
        run_check MediaUnlockTest_DStv ${1} &
        # MediaUnlockTest_Showmax &
        run_check MediaUnlockTest_Viu.com ${1} &
        # MediaUnlockTest_ParamountPlus &
    )
    wait
    local array=("DStv:" "Showmax:" "Viu.com:")
    echo_Result ${result} ${array}
    echo "======================================="
}

function Sport_UnlockTest() {
    echo "===============[ Sport ]==============="
    local result=$(
    run_check MediaUnlockTest_Dazn ${1} &
    run_check MediaUnlockTest_ESPNPlus ${1} &
    run_check MediaUnlockTest_NBATV ${1} &
    run_check MediaUnlockTest_FuboTV ${1} &
    run_check MediaUnlockTest_MolaTV ${1} &
    run_check MediaUnlockTest_SetantaSports ${1} &
    run_check MediaUnlockTest_OptusSports ${1} &
    run_check MediaUnlockTest_BeinConnect ${1} &
    run_check MediaUnlockTest_EurosportRO ${1} &
    )
    wait
    local array=("Dazn:" "Star+:" "ESPN+:" "NBA TV:" "Fubo TV:" "Mola TV:" "Setanta Sports:" "Optus Sports:" "Bein Sports Connect:" "Eurosport RO:")
    echo_Result ${result} ${array}
    echo "======================================="
}

function AI_UnlockTest() {
    echo "============[ AI Platform ]============"
    local result=$(
    run_check MediaUnlockTest_ChatGPT ${1} &
    run_check MediaUnlockTest_Sora ${1} &
    AIUnlockTest_Gemini_location ${1} &
    AIUnlockTest_Copilot ${1} &
    AIUnlockTest_Claude ${1} &
    )
    wait
    local array=("ChatGPT" "Copilot" "Gemini" "Sora:" "Claude:" )
    echo_Result ${result} ${array}

    echo "======================================="
}

function CheckV4() {
    if [ -f "$ip_fetch_trace" ]; then
        cat "$ip_fetch_trace"
        rm -f "$ip_fetch_trace"
        echo ""
    fi
    if [[ "$language" == "e" ]]; then
        if [[ "$NetworkType" == "6" ]]; then
            isv4=0
            echo -e "${Font_SkyBlue}User Choose to Test Only IPv6 Results, Skipping IPv4 Testing...${Font_Suffix}"
        else
            echo -e " ${Font_SkyBlue}** Checking Results Under IPv4${Font_Suffix} "
            echo "--------------------------------"
            echo -e " ${Font_SkyBlue}** Your Network Provider: AS${local_as4} ${local_isp4} (${local_ipv4_asterisk})${Font_Suffix} "
            if [ -n  "$local_ipv4"  ]; then
                isv4=1
            else
                echo -e "${Font_SkyBlue}No IPv4 Connectivity Found, Abort IPv4 Testing...${Font_Suffix}"
                isv4=0
            fi

            echo ""
        fi
    else
        if [[ "$NetworkType" == "6" ]]; then
            isv4=0
            echo -e "${Font_SkyBlue}用户选择只检测IPv6结果，跳过IPv4检测...${Font_Suffix}"
        else
            echo -e " ${Font_SkyBlue}** 正在测试IPv4解锁情况${Font_Suffix} "
            echo "--------------------------------"
            echo -e " ${Font_SkyBlue}** 您的网络为: AS${local_as4} ${local_isp4} (${local_ipv4_asterisk})${Font_Suffix} "
            if [ -n  "$local_ipv4"  ]; then
                isv4=1
            else
                echo -e "${Font_SkyBlue}当前网络不支持IPv4,跳过...${Font_Suffix}"
                isv4=0
            fi

            echo ""
        fi
    fi
}

function CheckV6() {
    if [[ "$language" == "e" ]]; then
        if [[ "$NetworkType" == "4" ]]; then
            isv6=0
            if [ -z "$usePROXY" ]; then
                echo -e "${Font_SkyBlue}User Choose to Test Only IPv4 Results, Skipping IPv6 Testing...${Font_Suffix}"
            fi
        else
            if [ -n  "$local_ipv6"  ]; then
                echo ""
                echo ""
                echo -e " ${Font_SkyBlue}** Checking Results Under IPv6${Font_Suffix} "
                echo "--------------------------------"
                echo -e " ${Font_SkyBlue}** Your Network Provider:  AS${local_as6} ${local_isp6} (${local_ipv6_asterisk})${Font_Suffix} "
                isv6=1
            else
                echo -e "${Font_SkyBlue}No IPv6 Connectivity Found, Abort IPv6 Testing...${Font_Suffix}"
                isv6=0
            fi
            echo -e ""
        fi

    else
        if [[ "$NetworkType" == "4" ]]; then
            isv6=0
            if [ -z "$usePROXY" ]; then
                echo -e "${Font_SkyBlue}用户选择只检测IPv4结果，跳过IPv6检测...${Font_Suffix}"
            fi
        else
            if [ -n  "$local_ipv6"  ]; then
                echo ""
                echo ""
                echo -e " ${Font_SkyBlue}** 正在测试IPv6解锁情况${Font_Suffix} "
                echo "--------------------------------"
                echo -e " ${Font_SkyBlue}** 您的网络为: AS${local_as6} ${local_isp6} (${local_ipv6_asterisk})${Font_Suffix} "
                isv6=1
            else
                echo -e "${Font_SkyBlue}当前主机不支持IPv6,跳过...${Font_Suffix}"
                isv6=0
            fi
            echo -e ""
        fi
    fi
}


function Goodbye() {
    if [[ "$language" == "e" ]]; then
        echo -e "${Font_Green}Testing Done! Thanks for Using This Script! ${Font_Suffix}"
    else
        echo -e "${Font_Green}本次测试已结束，感谢使用此脚本 ${Font_Suffix}"
    fi
}

clear

function ScriptTitle() {
    if [[ "$language" == "e" ]]; then
        echo -e " [OTT & AI Region Restriction Test]"
        echo ""
        echo -e "${Font_Green}Github Repository:${Font_Suffix} ${Font_Yellow} https://github.com/TragicLife/RegionRestrictionCheck ${Font_Suffix}"
        echo -e "${Font_Purple}Supporting Environment: Linux, UNIX & Cygwin with bash + jq${Font_Suffix}"
        echo ""
        echo -e " ** Test Starts At: $(date)"
        echo ""
    else
        echo -e " [流媒体+AI 区域限制测试]"
        echo ""
        echo -e "${Font_Green}项目地址${Font_Suffix} ${Font_Yellow}https://github.com/TragicLife/RegionRestrictionCheck ${Font_Suffix}"
         echo -e "${Font_Purple}支持: 具有 bash + jq 的 任何 Linux, UNIX 及 Cygwin 环境${Font_Suffix}"
        echo ""
        echo -e " ** 测试时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo ""
    fi
}
ScriptTitle

function Start() {
    if [[ "$language" == "e" ]]; then
        echo -e "${Font_Blue}Please Select Test Region or Press ENTER to Test All Regions${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [1]: [ Multination + Taiwan ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [2]: [ Multination + Hong Kong ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [3]: [ Multination + Japan ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [4]: [ Multination + North America ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [5]: [ Multination + South America ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [6]: [ Multination + Europe ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [7]: [ Multination + Oceania ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [8]: [ Multination + Korean ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [9]: [ Multination + Asia ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number [10]: [ AI Platform ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number [11]: [ Multination + Africa ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number  [0]: [ Multination Only ]${Font_Suffix}"
        echo -e "${Font_SkyBlue}Input Number [99]: [ Sport Platforms ]${Font_Suffix}"
        read -p "Please Input the Correct Number or Press ENTER:" num
    else
        echo -e "${Font_Blue}请选择检测项目，直接按回车将进行全区域检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [1]: [ 跨国平台+台湾平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [2]: [ 跨国平台+香港平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [3]: [ 跨国平台+日本平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [4]: [ 跨国平台+北美平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [5]: [ 跨国平台+南美平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [6]: [ 跨国平台+欧洲平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [7]: [跨国平台+大洋洲平台]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [8]: [ 跨国平台+韩国平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [9]: [ 跨国平台+亚洲平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字 [10]: [      AI 平台     ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字 [11]: [ 跨国平台+非洲平台 ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字  [0]: [   只进行跨国平台  ]检测${Font_Suffix}"
        echo -e "${Font_SkyBlue}输入数字 [99]: [   体育直播平台    ]检测${Font_Suffix}"
        read -p "请输入正确数字或直接按回车:" num
    fi
}
Start

function RunScript() {

    if [[ -n "${num}" ]]; then
        if [[ "$num" -eq 1 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                TW_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                TW_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 2 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                HK_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                HK_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 3 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                JP_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                JP_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 4 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                NA_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                NA_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 5 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                SA_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                SA_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 6 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                EU_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                EU_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 7 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                OA_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                OA_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 8 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                KR_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                KR_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 9 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                Asia_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                Asia_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 10 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                AI_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                AI_UnlockTest 6
            fi
            Goodbye
            
        elif [[ "$num" -eq 11 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
                AF_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
                AF_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 99 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Sport_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Sport_UnlockTest 6
            fi
            Goodbye

        elif [[ "$num" -eq 0 ]]; then
            clear
            ScriptTitle
            CheckV4
            if [[ "$isv4" -eq 1 ]]; then
                Global_UnlockTest 4
            fi
            CheckV6
            if [[ "$isv6" -eq 1 ]]; then
                Global_UnlockTest 6
            fi
            Goodbye

        else
            echo -e "${Font_Red}请重新执行脚本并输入正确号码${Font_Suffix}"
            echo -e "${Font_Red}Please Re-run the Script with Correct Number Input${Font_Suffix}"
            return
        fi
    else
        clear
        ScriptTitle
        CheckV4
        if [[ "$isv4" -eq 1 ]]; then
            Global_UnlockTest 4
            TW_UnlockTest 4
            HK_UnlockTest 4
            JP_UnlockTest 4
            NA_UnlockTest 4
            SA_UnlockTest 4
            EU_UnlockTest 4
            OA_UnlockTest 4
            KR_UnlockTest 4
            Asia_UnlockTest 4
            AI_UnlockTest 4
            AF_UnlockTest 4
        fi
        CheckV6
        if [[ "$isv6" -eq 1 ]]; then
            Global_UnlockTest 6
            TW_UnlockTest 6
            HK_UnlockTest 6
            JP_UnlockTest 6
            NA_UnlockTest 6
            SA_UnlockTest 6
            EU_UnlockTest 6
            OA_UnlockTest 6
            KR_UnlockTest 6
            Asia_UnlockTest 6
            AI_UnlockTest 6
            AF_UnlockTest 6
        fi
        Goodbye
    fi
}
wait
RunScript
