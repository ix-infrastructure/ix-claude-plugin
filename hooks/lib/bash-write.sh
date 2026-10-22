#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# hooks/lib/bash-write.sh — Can this Bash command line change a file?
#
# Usage:
#   source "${_HOOK_DIR}/lib/bash-write.sh"
#   ix_bash_may_write "$COMMAND" || echo "every command on the line only reads"
#
# ix_bash_may_write returns 1 only when every command on the line can only
# read, and 0 (may write) for everything else. ix-dependents.sh uses it to skip
# `ix hook claude-post-edit` after `cat`, `ls` or `git diff`: that report comes
# from the working tree's diff, so the next command that may write catches up
# on anything a wrong "reads" missed. A wrong "may write" only costs the old
# behaviour. So the rules lean to "may write":
#   - anything unknown: a command not in the list below, a shell keyword (`if`,
#     `for`), `$(...)` or backticks (also inside double quotes), `<(...)` and
#     `>(...)`, `<>`, an unterminated quote, a line over 1024 characters
#   - any output redirect to a file (`>`, `>>`, `>|`, `&>`, `>&file`) except to
#     /dev/null, /dev/stdout or /dev/stderr; fd dups (`2>&1`, `>&2`) are fine
#   - any heredoc or herestring (`<<`, `<<<`): it usually feeds a script
#   - in-place flags: `sed -i`/`--in-place`, `awk -i inplace`, `sort -o`,
#     `tree -o`, `less -o`, `file -C`, `git diff/log --output`; output operands
#     (`uniq in out`, `xxd in out`); scripts that write or run commands (sed
#     `w`/`W`/`e`/`-f`, awk `>`/`|`/`system`/`-f`, `rg --pre`, `git --ext-diff`);
#     `find -delete/-exec/-execdir/-ok/-okdir/-fprint*/-fls`, `fd -x/-X/--exec*`
# Quoted text is data, not syntax (`grep -E "a|b"` is one command). The line
# splits on `&&`, `||`, `|`, `|&`, `;`, `&`, newlines and subshell parens; each
# command drops its leading `VAR=value` assignments, `!`, `{`/`}` and the
# wrappers `time`, `nice`, `command` and `xargs` (with their options).
# `git` reads only as status, diff, log, show, blame, grep, ls-files, ls-tree,
# rev-parse, cat-file, describe, shortlog, bare `branch` and `remote -v`.
#
# Pure bash: no subprocess, so a hook can call it before deciding whether the
# rest of its work (the library, jq, ix) is needed at all.

ix_bash_may_write() {
  # Bytes, not characters: in a UTF-8 locale every ${_s:_i:1} walks the string
  # from the start. No syntax character is part of a multibyte sequence.
  local LC_ALL=C
  local _s="${1-}"
  local _n=${#_s} _i=0 _c _q="" _w="" _hw=0 _redir=0 _j
  local -a _words=()
  # Runs of characters with no meaning in their quoting state, taken in one step.
  local _re_sed_write='(^|[^A-Za-z])([wW][[:space:]]+[^[:space:]]|e([[:space:];}]|$))'
  local _re_plain="^[^[:space:]'\"\\\`\$;&|<>()]+" _re_sq="^[^']+" _re_dq="^[^\"\\\`\$]+"
  [ "$_n" -gt 0 ] && [ "$_n" -le 1024 ] || return 0

  # The _ix_bw_* helpers share this function's locals (bash scoping) and
  # return 1 when they find a possible write.
  while [ "$_i" -lt "$_n" ]; do
    case "$_q" in
      "'") [[ "${_s:_i}" =~ $_re_sq ]] ;;
      '"') [[ "${_s:_i}" =~ $_re_dq ]] ;;
      *) [[ "${_s:_i}" =~ $_re_plain ]] && _hw=1 ;;
    esac && {
      _w+="${BASH_REMATCH[0]}"; _i=$(( _i + ${#BASH_REMATCH[0]} )); continue
    }
    _c="${_s:_i:1}"
    if [ "$_q" = "'" ]; then
      # Only the closing quote gets here.
      _q=""; _i=$(( _i + 1 )); continue
    fi
    if [ "$_q" = '"' ]; then
      case "$_c" in
        '"') _q="" ;;
        '\') _i=$(( _i + 1 )); _w+="${_s:_i:1}" ;;
        '`') return 0 ;;
        '$') [ "${_s:_i+1:1}" = "(" ] && return 0; _w+="$_c" ;;
        *) _w+="$_c" ;;
      esac
      _i=$(( _i + 1 )); continue
    fi
    case "$_c" in
      "'"|'"') _q="$_c"; _hw=1 ;;
      '\')
        _i=$(( _i + 1 ))
        if [ "${_s:_i:1}" != $'\n' ]; then _w+="${_s:_i:1}"; _hw=1; fi ;;
      '`') return 0 ;;
      '$') [ "${_s:_i+1:1}" = "(" ] && return 0; _w+="$_c"; _hw=1 ;;
      ' '|$'\t'|$'\r') _ix_bw_endword || return 0 ;;
      $'\n'|';'|'('|')') _ix_bw_endseg || return 0 ;;
      '|')
        _ix_bw_endseg || return 0
        case "${_s:_i+1:1}" in '|'|'&') _i=$(( _i + 1 )) ;; esac ;;
      '&')
        case "${_s:_i+1:1}" in
          '>') _i=$(( _i + 1 )); _ix_bw_redirect_out || return 0 ;;
          '&') _ix_bw_endseg || return 0; _i=$(( _i + 1 )) ;;
          *) _ix_bw_endseg || return 0 ;;
        esac ;;
      '>') _ix_bw_redirect_out || return 0 ;;
      '<')
        case "${_s:_i+1:1}" in
          '<'|'('|'>') return 0 ;;
          '&')
            _ix_bw_fd_prefix || return 0
            _j=$(( _i + 2 ))
            while [[ "${_s:_j:1}" == [0-9-] ]]; do _j=$(( _j + 1 )); done
            _i=$(( _j - 1 )) ;;
          *) _ix_bw_fd_prefix || return 0; _redir=2 ;;
        esac ;;
      *) _w+="$_c"; _hw=1 ;;
    esac
    _i=$(( _i + 1 ))
  done
  [ -z "$_q" ] || return 0
  _ix_bw_endseg || return 0
  return 1
}

# A digit-only word right before a redirect is its fd (`2>`); anything else is
# a word of its own (`echo hi>out`).
_ix_bw_fd_prefix() {
  if [ "$_hw" -eq 1 ] && [[ "$_w" =~ ^[0-9]+$ ]]; then
    _w=""; _hw=0
  else
    _ix_bw_endword || return 1
  fi
  [ "$_redir" -eq 0 ] || return 1
}

# At an output `>` (or the `>` of `&>`): `>>` and `>|` append or clobber, `>&N`
# and `>&-` are dups, `>(` runs a command, and anything else names a target
# word that must be /dev/null, /dev/stdout or /dev/stderr.
_ix_bw_redirect_out() {
  _ix_bw_fd_prefix || return 1
  case "${_s:_i+1:1}" in '>'|'|') _i=$(( _i + 1 )) ;; esac
  case "${_s:_i+1:1}" in
    '(') return 1 ;;
    '&')
      _j=$(( _i + 2 ))
      while [[ "${_s:_j:1}" == [0-9] ]]; do _j=$(( _j + 1 )); done
      if [ "$_j" -gt $(( _i + 2 )) ] || [ "${_s:_j:1}" = "-" ]; then
        [ "${_s:_j:1}" = "-" ] && _j=$(( _j + 1 ))
        _i=$(( _j - 1 ))
        return 0
      fi
      _i=$(( _i + 1 )) ;;
  esac
  _redir=1
}

_ix_bw_endword() {
  [ "$_hw" -eq 1 ] || return 0
  case "$_redir" in
    1) case "$_w" in /dev/null|/dev/stdout|/dev/stderr) ;; *) return 1 ;; esac ;;
    2) ;;
    *) _words+=("$_w") ;;
  esac
  _redir=0; _w=""; _hw=0
}

_ix_bw_endseg() {
  _ix_bw_endword || return 1
  [ "$_redir" -eq 0 ] || return 1
  [ "${#_words[@]}" -eq 0 ] && return 0
  _ix_bw_command_reads || { _words=(); return 1; }
  _words=()
}

# Returns 0 when the command in _words can only read.
_ix_bw_command_reads() {
  local _k=0 _m=${#_words[@]} _cmd _a
  while [ "$_k" -lt "$_m" ]; do
    _cmd="${_words[_k]}"
    if [[ "$_cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then _k=$(( _k + 1 )); continue; fi
    case "$_cmd" in
      '!'|'{'|'}') _k=$(( _k + 1 )) ;;
      time|command)
        _k=$(( _k + 1 ))
        while [[ "${_words[_k]-}" == -* ]]; do _k=$(( _k + 1 )); done ;;
      nice)
        _k=$(( _k + 1 ))
        while [[ "${_words[_k]-}" == -* ]]; do
          [ "${_words[_k]}" = "-n" ] && _k=$(( _k + 1 ))
          _k=$(( _k + 1 ))
        done ;;
      xargs)
        _k=$(( _k + 1 ))
        while [[ "${_words[_k]-}" == -* ]]; do
          case "${_words[_k]}" in -a|-d|-E|-I|-L|-n|-P|-s) _k=$(( _k + 1 )) ;; esac
          _k=$(( _k + 1 ))
        done
        # xargs with no command runs echo.
        [ "$_k" -lt "$_m" ] || return 0 ;;
      *) break ;;
    esac
  done
  [ "$_k" -lt "$_m" ] || return 0
  _cmd="${_words[_k]}"
  local -a _args=("${_words[@]:_k+1}")

  case "$_cmd" in
    cat|head|tail|ls|grep|egrep|fgrep|ag|wc|echo|printf|pwd|cd|cut|tr|nl|\
    which|type|stat|du|df|more|diff|cmp|jq|true|false|test|'['|'[['|\
    basename|dirname|realpath|readlink|date|whoami|id|uname|column|fold|comm|join|\
    paste|od|hexdump|strings|md5sum|sha1sum|sha256sum)
      return 0 ;;
    # A second file operand is the output file.
    uniq|xxd) _ix_bw_operands_le 1 ;;
    rg)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in --pre|--pre=*) return 1 ;; esac
      done
      return 0 ;;
    less)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in --log-file*|--LOG-FILE*) return 1 ;; --*) ;; -*[oO]*) return 1 ;; esac
      done
      return 0 ;;
    file)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in --compile) return 1 ;; --*) ;; -*C*) return 1 ;; esac
      done
      return 0 ;;
    sort)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in --output*) return 1 ;; --*) ;; -*o*) return 1 ;; esac
      done
      return 0 ;;
    tree)
      for _a in ${_args[@]+"${_args[@]}"}; do [ "$_a" = "-o" ] && return 1; done
      return 0 ;;
    find)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) return 1 ;; esac
      done
      return 0 ;;
    fd)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in -x|-X|--exec|--exec=*|--exec-batch|--exec-batch=*) return 1 ;; esac
      done
      return 0 ;;
    # The script itself can write: `w file`, `s/a/b/w file`, `W`, or run `e`.
    # A script from a file (-f) is unknown.
    sed)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in --in-place*|--file*) return 1 ;; --*) ;; -*[if]*) return 1 ;; esac
        [[ "$_a" =~ $_re_sed_write ]] && return 1
      done
      return 0 ;;
    # The program can write: `print > "f"`, `print | "cmd"`, `system()`.
    awk|gawk)
      for _a in ${_args[@]+"${_args[@]}"}; do
        case "$_a" in *inplace*|*'>'*|*'|'*|*system*|-f|--file*) return 1 ;; esac
      done
      return 0 ;;
    git) _ix_bw_git_reads ;;
    *) return 1 ;;
  esac
}

# Returns 0 when at most N of _args are operands (words not starting with -).
_ix_bw_operands_le() {
  local _a _ops=0
  for _a in ${_args[@]+"${_args[@]}"}; do
    case "$_a" in -*) ;; *) _ops=$(( _ops + 1 )) ;; esac
  done
  [ "$_ops" -le "$1" ]
}

_ix_bw_git_reads() {
  local _g=0 _gm=${#_args[@]}
  while [ "$_g" -lt "$_gm" ]; do
    case "${_args[_g]}" in
      -C|-c|--git-dir|--work-tree|--namespace) _g=$(( _g + 2 )) ;;
      -*) _g=$(( _g + 1 )) ;;
      *) break ;;
    esac
  done
  [ "$_g" -lt "$_gm" ] || return 1
  # Flags that write a file or run a configured program.
  local _ga
  for _ga in "${_args[@]:_g+1}"; do
    case "$_ga" in --output|--output=*|--ext-diff|-O*|--open-files-in-pager*) return 1 ;; esac
  done
  case "${_args[_g]}" in
    status|diff|log|show|blame|grep|ls-files|ls-tree|rev-parse|cat-file|describe|shortlog) return 0 ;;
    branch) [ $(( _gm - _g )) -eq 1 ] ;;
    remote) [ $(( _gm - _g )) -eq 2 ] && [ "${_args[_g+1]}" = "-v" ] ;;
    *) return 1 ;;
  esac
}
