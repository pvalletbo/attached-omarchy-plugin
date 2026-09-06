# Attached Sessions for Omarchy

> **AI contribution notice:** This document was created with contributions from an AI coding agent at the explicit request of the project maintainer.

A keyboard-first Omarchy Shell overlay for searching synchronized [Attached](https://github.com/pvalletbo/attached) sessions and opening the selected remote Herdr session in a terminal.

## Requirements

- Omarchy 4.0.1 or newer with `omarchy` and `omarchy-shell` on `PATH`.
- An Attached download account.
- An Attached release containing the machine-readable `attached sessions` catalog. This is currently being reviewed in [Attached PR #26](https://github.com/pvalletbo/attached/pull/26).

The setup script installs Attached when it is not already available on `PATH`. Existing installations are left unchanged. 1Password is optional.

## Install

Review the repository before enabling it: Omarchy plugins execute unsandboxed inside the long-lived shell process.

```bash
omarchy plugin add https://github.com/pvalletbo/attached-omarchy-plugin.git
~/.config/omarchy/plugins/pvalletbo.attached/install.sh
```

Omarchy intentionally runs no plugin install hook. The second command:

- validates the Git-managed plugin checkout;
- installs a missing Attached CLI with its documented HTTPS-only installer command;
- adds one managed **Super+Ctrl+Shift+H** shortcut to `~/.config/hypr/bindings.lua`;
- creates `${XDG_CONFIG_HOME:-$HOME/.config}/attached/omarchy.json` only when absent;
- rescans Omarchy Shell and enables `pvalletbo.attached`.

The script performs all refusal checks before downloading or writing anything. It never overwrites the user-owned provider configuration or a modified shortcut block. Re-running it is idempotent. If shell setup fails, it restores the previous bindings and newly created provider configuration while retaining the Git checkout and any successfully installed Attached CLI so setup can be retried.

The missing CLI is installed using the command published by Attached:

```bash
curl --proto '=https' --tlsv1.2 -LsSf https://install.attached.sh | sh
```

This downloads and executes Attached's installer. Review [install.attached.sh](https://install.attached.sh) before running the plugin setup if that trust boundary is not acceptable.

Update the Git-managed plugin with:

```bash
omarchy plugin update pvalletbo.attached
```

## Configuration

The default configuration prompts for the regular encryption password:

```json
{
  "encryptionPasswordProvider": "password"
}
```

Set `encryptionPasswordProvider` to `"1password"` to use the 1Password CLI instead. Existing encrypted state is not migrated when this setting changes, so select the provider used to create it.

Press **Super+Ctrl+Shift+H** to toggle the picker. With the default provider, enter the encryption password first. Type to fuzzy-filter, use **Up/Down** or **Ctrl+P/Ctrl+N** to move, **Enter** or a mouse click to connect, **Escape** to clear or dismiss, and **Ctrl+R** to retry. With the 1Password provider, **Ctrl+O** opens or offers to install 1Password.

## Remove

Run the bundled removal helper before its Git checkout is deleted:

```bash
~/.config/omarchy/plugins/pvalletbo.attached/uninstall.sh
```

Pass `--yes` for noninteractive removal. The helper safely removes its exact managed shortcut and delegates plugin removal to Omarchy. It retains the Attached CLI and `${XDG_CONFIG_HOME:-$HOME/.config}/attached/omarchy.json`; remove those separately only if they are no longer needed.

## Security and integration contract

`attached sessions` is the machine-readable boundary. The password provider invokes `attached sessions --password-stdin` and writes the password to an anonymous standard-input pipe. The password is never placed in process arguments or environment variables and is cleared from the overlay immediately after writing. The 1Password provider invokes `attached --use-1password sessions`.

The overlay rejects malformed, oversized, and inconsistent catalog rows before display. It passes `attached attach <target>` to `omarchy-launch-terminal` as an argument array rather than a shell string, so a target cannot become shell syntax. Session and query text is rendered as plain text. Raw command stderr, passwords, targets, and catalog payloads are not logged or rendered as diagnostics.

The plugin can read:

- `${XDG_CONFIG_HOME:-$HOME/.config}/attached/omarchy.json`;
- Attached's synchronized state through the `attached` CLI.

It can execute:

- `attached sessions` and `attached attach`;
- `omarchy-launch-terminal` for the selected session;
- `omarchy-launch-1password` when explicitly requested.

## Validate

Portable checks:

```bash
node --test tests/*.test.js
bash -n install.sh uninstall.sh
qmlformat Overlay.qml > /dev/null
```

On an Omarchy host:

```bash
omarchy plugin validate .
```

Before release, test password entry, 1Password authorization, keyboard and mouse selection, and a real remote attachment in an Omarchy Wayland session.

## License

This plugin is available under the [MIT License](LICENSE). Attached and Omarchy are separate dependencies distributed under their respective licenses.
