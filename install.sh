#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/netdoctor-repair-macos.zsh"
SOURCE_TEST="$SCRIPT_DIR/test-netdoctor.zsh"

DEFAULT_PREFIX="/usr/local/bin"
PREFIX="${1:-$DEFAULT_PREFIX}"
ALIAS_PROMPT_MODE="${NETDOCTOR_ADD_ALIAS:-ask}"

resolve_user_home() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    dscl "." -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}'
  else
    print -r -- "$HOME"
  fi
}

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  print -u2 -- "Error: source script not found: $SOURCE_SCRIPT"
  exit 1
fi

if [[ ! -f "$SOURCE_TEST" ]]; then
  print -u2 -- "Error: test harness not found: $SOURCE_TEST"
  exit 1
fi

mkdir -p "$PREFIX" 2>/dev/null || {
  print -u2 -- "Error: cannot create or access install directory: $PREFIX"
  print -u2 -- "Hint: try sudo ./install.sh or pass a writable directory, e.g. ./install.sh \$HOME/bin"
  exit 1
}

install_file() {
  local src="$1"
  local dst="$2"
  cp "$src" "$dst"
  chmod 755 "$dst"
}

install_file "$SOURCE_SCRIPT" "$PREFIX/netdoctor-repair-macos.zsh"
install_file "$SOURCE_TEST" "$PREFIX/test-netdoctor.zsh"

print -r -- "Installed: $PREFIX/netdoctor-repair-macos.zsh"
print -r -- "Installed: $PREFIX/test-netdoctor.zsh"

case "$ALIAS_PROMPT_MODE" in
  yes)
    reply="yes"
    ;;
  no)
    reply="no"
    ;;
  ask)
    if [[ -r /dev/tty ]]; then
      print -r -- ""
      print -r -- "Optional: add a shell alias \`netdoctor\` to your zsh config? [y/N]"
      read -r reply </dev/tty
    else
      reply="no"
    fi
    ;;
  *)
    print -r -- ""
    print -r -- "Warning: invalid NETDOCTOR_ADD_ALIAS value '$ALIAS_PROMPT_MODE' (use yes|no|ask). Falling back to ask."
    if [[ -r /dev/tty ]]; then
      print -r -- "Optional: add a shell alias \`netdoctor\` to your zsh config? [y/N]"
      read -r reply </dev/tty
    else
      reply="no"
    fi
    ;;
esac

if [[ "$reply" == "yes" || "$reply" == "y" ]]; then
  print -r -- ""
  USER_HOME="$(resolve_user_home)"
  ZSHRC="$USER_HOME/.zshrc"
  ALIAS_BEGIN="# >>> NetDoctor alias >>>"
  ALIAS_END="# <<< NetDoctor alias <<<"
  ALIAS_BLOCK="${ALIAS_BEGIN}
alias netdoctor=\"$PREFIX/netdoctor-repair-macos.zsh\"
${ALIAS_END}"

  touch "$ZSHRC"
  if grep -qF "$ALIAS_BEGIN" "$ZSHRC"; then
    ALIAS_BLOCK="$ALIAS_BLOCK" perl -0pi -e 's/\Q# >>> NetDoctor alias >>>\E.*?\Q# <<< NetDoctor alias <<<\E\n?/$ENV{ALIAS_BLOCK}\n/s' "$ZSHRC"
  else
    {
      print -r -- ""
      print -r -- "$ALIAS_BLOCK"
    } >> "$ZSHRC"
  fi
  print -r -- "Added alias \`netdoctor\` to $ZSHRC"
  print -r -- "Reload it with: source $ZSHRC"
else
  print -r -- ""
  print -r -- "Tip: you can add a shell alias later with: alias netdoctor=\"$PREFIX/netdoctor-repair-macos.zsh\""
fi

print -r -- ""
print -r -- "Run:"
print -r -- "  $PREFIX/test-netdoctor.zsh"
print -r -- "  $PREFIX/netdoctor-repair-macos.zsh --help"








