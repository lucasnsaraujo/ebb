#!/bin/zsh
# Runs `ebb --uninstall-data` against a throwaway home and checks that it asks first, removes the paths
# in docs/paths.md and leaves everything else alone. For CI; the unit tests cover the same logic.
#
#   scripts/check-uninstall.sh [path to the EbbCLI binary]     default: .build/release/EbbCLI
set -euo pipefail
cd "${0:A:h}/.."

# The command also looks for its link in /usr/local/bin, outside the throwaway home.
[[ ! -e /usr/local/bin/ebb && ! -L /usr/local/bin/ebb ]] || { print "Refusing to run: /usr/local/bin/ebb exists. Use a disposable session." >&2; exit 1 }

cli="${1:-.build/release/EbbCLI}"
[[ $cli == /* ]] || cli="$PWD/$cli"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HOME="$root/home" CFFIXED_USER_HOME="$root/home"

ebb_paths=("${(@f)$(sed -nE 's|^ *"~/(.*)",?$|\1|p' docs/paths.md)}")
decoys=(".cli-proxy-api/config.yaml" ".config/other/settings" "Library/Application Support/Other/state" ".local/bin/other-tool")
failures=0
code=0

seed() {
    rm -rf "$HOME" && mkdir -p "$HOME"
    local path
    for path in "${ebb_paths[@]}"; do
        if [[ $path == *.plist || $path == *.binarycookies ]]; then
            mkdir -p "$HOME/${path:h}" && print x > "$HOME/$path"
        else
            mkdir -p "$HOME/$path" && print x > "$HOME/$path/file"
        fi
    done
    for path in "${decoys[@]}"; do mkdir -p "$HOME/${path:h}" && print x > "$HOME/$path"; done
    ln -s /Applications/Ebb.app/Contents/Helpers/ebb "$HOME/.local/bin/ebb"
}

# with_terminal <answer> <command...>: runs the command with a terminal on its input and types the answer.
with_terminal() {
    python3 -I - "$@" <<'PY'
import os, pty, sys
answer, *command = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(command[0], command)
os.write(fd, (answer + "\n").encode())
output = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    output += chunk
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(output)
sys.exit(os.waitstatus_to_exitcode(status))
PY
}

check() {  # check <what> <command...>
    local what=$1; shift
    if "$@"; then print "ok     $what"; else print "FAILED $what"; failures=$((failures + 1)); fi
}

exit_code_is() { (( code == $1 )) }

ebb_files_all_there() {
    local path
    for path in "${ebb_paths[@]}"; do [[ -e $HOME/$path ]] || return 1; done
    [[ -L $HOME/.local/bin/ebb ]]
}

ebb_files_all_gone() {
    local path
    for path in "${ebb_paths[@]}"; do [[ ! -e $HOME/$path ]] || return 1; done
    [[ ! -L $HOME/.local/bin/ebb ]]
}

decoys_all_there() {
    local path
    for path in "${decoys[@]}"; do [[ -e $HOME/$path ]] || return 1; done
}

print "${#ebb_paths} paths from docs/paths.md"
(( ${#ebb_paths} >= 5 )) || { print "FAILED read too few paths from docs/paths.md" >&2; exit 1 }

seed
code=0; "$cli" --uninstall-data < /dev/null > "$root/out" 2>&1 || code=$?
check "with no terminal and no --yes it exits 1" exit_code_is 1
check "with no terminal and no --yes it removes nothing" ebb_files_all_there

seed
code=0; with_terminal no "$cli" --uninstall-data > "$root/out" 2>&1 || code=$?
check "answering no exits 0" exit_code_is 0
check "answering no removes nothing" ebb_files_all_there

seed
code=0; with_terminal yes "$cli" --uninstall-data > "$root/out" 2>&1 || code=$?
cat "$root/out"
check "answering yes exits 0" exit_code_is 0
check "answering yes removes Ebb's paths and its command link" ebb_files_all_gone
check "answering yes leaves everything else" decoys_all_there

seed
code=0; "$cli" --uninstall-data --yes < /dev/null > "$root/out" 2>&1 || code=$?
check "--yes exits 0" exit_code_is 0
check "--yes removes Ebb's paths and its command link" ebb_files_all_gone
check "--yes leaves everything else" decoys_all_there

code=0; "$cli" --uninstall-data --yes < /dev/null > "$root/out" 2>&1 || code=$?
check "with nothing left it still exits 0" exit_code_is 0

(( failures == 0 )) || { print "\n$failures check(s) failed" >&2; exit 1 }
print "\nuninstall behaves"
