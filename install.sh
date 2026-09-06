#!/usr/bin/env bash
set -euo pipefail

# Omarchy intentionally does not execute plugin install hooks. Run this script
# from the checkout created by `omarchy plugin add` to install the CLI
# dependency, register the global shortcut, and enable the plugin.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
omarchy_config_home="$HOME/.config"
attached_config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
destination="$omarchy_config_home/omarchy/plugins/pvalletbo.attached"
bindings="$omarchy_config_home/hypr/bindings.lua"
attached_config_dir="$attached_config_home/attached"
plugin_config="$attached_config_dir/omarchy.json"
config_source="$script_dir/config.json"
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

for command in omarchy omarchy-shell; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required Omarchy command not found: %s\n' "$command" >&2
    exit 1
  }
done

if [[ -L "$destination" ]]; then
  printf 'Refusing to configure a plugin installed through a symlink: %s\n' "$destination" >&2
  exit 1
fi
if [[ ! -d "$destination" ]]; then
  printf 'Install the plugin first with:\n  omarchy plugin add https://github.com/pvalletbo/attached-omarchy-plugin.git\n' >&2
  exit 1
fi
destination_dir=$(cd -- "$destination" && pwd -P)
if [[ $script_dir != "$destination_dir" ]]; then
  printf 'Run the installer from the Git-managed Omarchy plugin checkout:\n  %s/install.sh\n' "$destination" >&2
  exit 1
fi

# Validate the checkout and every user-owned destination before downloading or
# writing anything.
omarchy plugin validate "$script_dir"

attached_missing=false
if ! command -v attached >/dev/null 2>&1; then
  attached_missing=true
  command -v curl >/dev/null 2>&1 || {
    printf 'Attached is not installed and curl is unavailable.\n' >&2
    exit 1
  }
fi

if [[ -L "$bindings" ]]; then
  printf 'Refusing to edit a symlinked bindings file: %s\n' "$bindings" >&2
  exit 1
fi
if [[ -e "$bindings" && ! -f "$bindings" ]]; then
  printf 'Refusing to edit a non-regular bindings path: %s\n' "$bindings" >&2
  exit 1
fi
begin_count=0
end_count=0
if [[ -f "$bindings" ]]; then
  begin_count=$(grep -Fxc -- "$marker" "$bindings" || true)
  end_count=$(grep -Fxc -- "$end_marker" "$bindings" || true)
fi
if [[ $begin_count != "$end_count" || $begin_count -gt 1 ]]; then
  printf 'Refusing to modify a partial or duplicate managed shortcut block in %s\n' "$bindings" >&2
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
    printf 'Refusing to overwrite a locally modified managed shortcut block in %s\n' "$bindings" >&2
    exit 1
  fi
fi

# The provider preference is user-owned: create it once, never overwrite it,
# and refuse symlinks or special files.
if [[ -L "$attached_config_dir" ]]; then
  printf 'Refusing to create configuration through a symlink: %s\n' "$attached_config_dir" >&2
  exit 1
fi
if [[ -e "$attached_config_dir" && ! -d "$attached_config_dir" ]]; then
  printf 'Refusing to replace a non-directory configuration path: %s\n' "$attached_config_dir" >&2
  exit 1
fi
if [[ -L "$plugin_config" ]]; then
  printf 'Refusing to replace a symlinked plugin configuration: %s\n' "$plugin_config" >&2
  exit 1
fi
if [[ -e "$plugin_config" && ! -f "$plugin_config" ]]; then
  printf 'Refusing to replace a non-regular plugin configuration: %s\n' "$plugin_config" >&2
  exit 1
fi

# Use Attached's documented installer only after all refusal checks pass.
if [[ $attached_missing == true ]]; then
  printf 'Attached is not installed; installing it from https://install.attached.sh...\n'
  if ! curl --proto '=https' --tlsv1.2 -LsSf https://install.attached.sh | sh; then
    printf 'Could not install Attached from https://install.attached.sh.\n' >&2
    exit 1
  fi
  hash -r
  if ! command -v attached >/dev/null 2>&1; then
    printf 'Attached was installed but is not available on PATH. Add its bin directory to PATH and retry.\n' >&2
    exit 1
  fi
fi

# Shortcut and newly-created provider state are transactional. The Git-managed
# plugin checkout and a successfully installed Attached CLI are retained if a
# shell operation fails, so the setup can be safely retried.
backup_root=$(mktemp -d "${TMPDIR:-/tmp}/attached-omarchy-setup.XXXXXX")
bindings_existed=false
if [[ -f "$bindings" ]]; then
  bindings_existed=true
  cp -p "$bindings" "$backup_root/bindings.lua"
fi
transaction_committed=false
plugin_config_created=false
config_dir_created=false
plugin_config_temp=""

finish_install() {
  status=$?
  trap - EXIT INT TERM
  if [[ $transaction_committed != true ]]; then
    set +e
    rm -f -- "$bindings"
    if [[ $bindings_existed == true ]]; then
      install -d -m 0755 "$(dirname -- "$bindings")"
      cp -p "$backup_root/bindings.lua" "$bindings"
    fi
    if [[ $plugin_config_created == true ]]; then
      rm -f -- "$plugin_config"
    fi
    if [[ $config_dir_created == true ]]; then
      rmdir -- "$attached_config_dir" 2>/dev/null || true
    fi
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    printf 'Setup failed; restored the previous bindings and provider configuration.\n' >&2
  fi
  if [[ -n $plugin_config_temp ]]; then
    rm -f -- "$plugin_config_temp"
  fi
  rm -rf -- "$backup_root"
  exit "$status"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

install -d -m 0755 "$(dirname -- "$bindings")"
touch "$bindings"
if [[ $begin_count -eq 0 ]]; then
  printf '\n' >> "$bindings"
  binding_block >> "$bindings"
fi

if [[ ! -d "$attached_config_dir" ]]; then
  install -d -m 0700 "$attached_config_dir"
  config_dir_created=true
fi
if [[ ! -e "$plugin_config" ]]; then
  plugin_config_temp=$(mktemp "$attached_config_dir/.omarchy.json.XXXXXX")
  install -m 0600 "$config_source" "$plugin_config_temp"
  ln -- "$plugin_config_temp" "$plugin_config"
  plugin_config_created=true
  rm -f -- "$plugin_config_temp"
  plugin_config_temp=""
fi

omarchy-shell shell rescanPlugins
omarchy plugin enable pvalletbo.attached
transaction_committed=true
printf 'Installed Attached picker. Press Super+Ctrl+Shift+H to open it.\n'
printf 'Encryption password provider configuration: %s (default: password).\n' "$plugin_config"
printf 'Set encryptionPasswordProvider to "1password" there to use 1Password instead.\n'
