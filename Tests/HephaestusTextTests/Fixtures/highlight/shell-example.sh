#!/bin/bash
# Comment
set -euo pipefail
name="world" # trailing comment
echo "Hello, $name ${name} ${name:-${default}} $1 $# $? $* $@ $$ $! $- $0 $ end"
echo 'single $name \n
across lines'
echo $'ansi \n \t \' end'
echo "escapes \$ \` \" \\ \n end"
echo "line \
continuation"
today=$(date +%Y-%m-%d)
count=$((1 + (2 * 3)))
nested="$(echo "$(whoami) in $(pwd)")"
legacy=`date \`inner\``
quoted="legacy `date` done"
if [[ -n "$name" ]]; then
    for i in 1 2 3; do echo "$i"; done
elif test -f file; then
    while read -r line; do printf '%s\n' "$line"; done < file
else
    case "$1" in
        start) echo start ;;
    esac
fi
function f() { local x=1; return 0; }
FOO=bar BAZ=qux command arg#notcomment a=b
cat <<EOF
here $name
EOF
time ls 2>&1 | grep x && true || false;# comment after semicolon
until false; do break; done
select x in a b; do continue; done
coproc cat
export PATH=/usr/bin:$PATH
(subshell #comment)
alias bg bind builtin caller cd compgen complete declare dirs disown enable eval exec exit fc fg getopts hash help history jobs kill let logout mapfile popd pushd pwd readarray readonly shift shopt source suspend times trap type typeset ulimit umask unalias unset wait
