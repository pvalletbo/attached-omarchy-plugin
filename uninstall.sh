#!/usr/bin/env bash
set -euo pipefail

# Remove the installer-managed shortcut before delegating plugin removal to
# Omarchy. Attached itself and the user-owned provider configuration remain.
omarchy_config_home="$HOME/.config"
bindings="$omarchy_config_home/hypr/bindings.lua"
marker='-- BEGIN Attached session picker'
end_marker='-- END Attached session picker'

binding_block() {
  printf '%s\n' "$marker"
  printf '%s\n' '-- o.bind registers a compositor-wide shortcut in Omarchy.'
  printf '%s\n' '-- The command toggles the plugin by its manifest id; edit the key chord if it conflicts.'
  printf '%s\n' 'o.bind('
  printf '%s\n' '  "SUPER + CTRL + SHIFT + H",'
  printf '%s\n' '  "Attached sessions",'
  printf '%s\n' '  "omarchy-shell shell toggle pvalletbo.attached"'
  printf '%s\n' ')'
  printf '%s\n' "$end_marker"
}

for argument in "$@"; do
  [[ $argument == --yes || $argument == -y ]] || {
    printf 'Usage: %s [--yes]\n' "$0" >&2
    exit 1
  }
done
command -v omarchy >/dev/null 2>&1 || {
  printf 'Required Omarchy command not found: omarchy\n' >&2
  exit 1
}

if [[ -L "$bindings" ]]; then
  printf 'Refusing to edit a symlinked bindings file: %s\n' "$bindings" >&2
  exit 1
fi
begin_count=0
end_count=0
if [[ -f "$bindings" ]]; then
  begin_count=$(grep -Fxc -- "$marker" "$bindings" || true)
  end_count=$(grep -Fxc -- "$end_marker" "$bindings" || true)
fi
if [[ $begin_count != "$end_count" || $begin_count -gt 1 ]]; then
  printf 'Refusing to remove a partial or duplicate managed shortcut block in %s\n' "$bindings" >&2
  exit 1
fi
if [[ $begin_count -eq 1 ]]; then
  installed_block=""
  collecting=false
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$marker" ]]; then
      collecting=true
    fi
    if [[ $collecting == true ]]; then
      [[ -z $installed_block ]] || installed_block+=$'\n'
      installed_block+=$line
    fi
    if [[ $collecting == true && $line == "$end_marker" ]]; then
      collecting=false
    fi
  done < "$bindings"
  expected_block=$(binding_block)
  if [[ $installed_block != "$expected_block" ]]; then
    printf 'Refusing to remove a locally modified managed shortcut block in %s\n' "$bindings" >&2
    exit 1
  fi
fi

backup_root=$(mktemp -d "${TMPDIR:-/tmp}/attached-omarchy-remove.XXXXXX")
cleanup() {
  rm -rf -- "$backup_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ $begin_count -eq 1 ]]; then
  cp -p "$bindings" "$backup_root/bindings.lua"
  awk -v begin="$marker" -v end="$end_marker" '
    $0 == begin { removing = 1; next }
    removing && $0 == end { removing = 0; next }
    !removing { print }
  ' "$bindings" > "$backup_root/bindings.new"
  cat "$backup_root/bindings.new" > "$bindings"
fi

if ! omarchy plugin remove pvalletbo.attached "$@"; then
  if [[ $begin_count -eq 1 ]]; then
    cp -p "$backup_root/bindings.lua" "$bindings"
  fi
  printf 'Plugin removal failed; restored the Attached shortcut.\n' >&2
  exit 1
fi

printf 'Removed the Attached picker shortcut.\n'
printf 'Attached and its provider configuration were retained.\n'
