"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repository = path.resolve(__dirname, "..");
const pluginId = "pvalletbo.attached";
const pluginFiles = [
  "config.json",
  "install.sh",
  "manifest.json",
  "Overlay.qml",
  "SessionModel.js",
  "uninstall.sh"
];

function createFixture({ attached = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "attached-omarchy-plugin-"));
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  const localBin = path.join(home, ".local", "bin");
  const plugin = path.join(home, ".config", "omarchy", "plugins", pluginId);
  const log = path.join(root, "commands.log");
  fs.mkdirSync(bin, { recursive: true });
  fs.mkdirSync(plugin, { recursive: true });

  for (const file of pluginFiles) {
    fs.copyFileSync(path.join(repository, file), path.join(plugin, file));
    fs.chmodSync(path.join(plugin, file), file.endsWith(".sh") ? 0o755 : 0o644);
  }

  fs.writeFileSync(
    path.join(bin, "omarchy"),
    [
      "#!/bin/sh",
      "invocation=\"omarchy $*\"",
      "printf '%s\\n' \"$invocation\" >> \"$ATTACHED_TEST_LOG\"",
      "if [ \"${ATTACHED_TEST_FAIL_COMMAND:-}\" = \"$invocation\" ]; then exit 42; fi",
      `if [ \"$invocation\" = \"omarchy plugin remove ${pluginId}\" ] || [ \"$invocation\" = \"omarchy plugin remove ${pluginId} --yes\" ]; then`,
      `  rm -rf -- \"$HOME/.config/omarchy/plugins/${pluginId}\"`,
      "fi",
      ""
    ].join("\n"),
    { mode: 0o755 }
  );
  fs.writeFileSync(
    path.join(bin, "omarchy-shell"),
    [
      "#!/bin/sh",
      "invocation=\"omarchy-shell $*\"",
      "printf '%s\\n' \"$invocation\" >> \"$ATTACHED_TEST_LOG\"",
      "if [ \"${ATTACHED_TEST_FAIL_COMMAND:-}\" = \"$invocation\" ]; then exit 42; fi",
      ""
    ].join("\n"),
    { mode: 0o755 }
  );
  fs.writeFileSync(
    path.join(bin, "curl"),
    [
      "#!/bin/sh",
      "printf 'curl %s\\n' \"$*\" >> \"$ATTACHED_TEST_LOG\"",
      "if [ \"${ATTACHED_TEST_CURL_FAIL:-}\" = true ]; then exit 22; fi",
      "cat <<'INSTALLER'",
      "#!/bin/sh",
      "set -eu",
      "install -d -m 0755 \"$HOME/.local/bin\"",
      "cat > \"$HOME/.local/bin/attached\" <<'ATTACHED'",
      "#!/bin/sh",
      "printf 'attached test binary\\n'",
      "ATTACHED",
      "chmod 0755 \"$HOME/.local/bin/attached\"",
      "INSTALLER",
      ""
    ].join("\n"),
    { mode: 0o755 }
  );
  if (attached) {
    fs.writeFileSync(path.join(bin, "attached"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  }

  return {
    root,
    home,
    bin,
    localBin,
    plugin,
    log,
    bindings: path.join(home, ".config", "hypr", "bindings.lua"),
    providerConfig: path.join(root, "xdg-config", "attached", "omarchy.json"),
    env: {
      ...process.env,
      HOME: home,
      XDG_CONFIG_HOME: path.join(root, "xdg-config"),
      PATH: `${bin}:${localBin}:/usr/bin`,
      ATTACHED_TEST_LOG: log
    }
  };
}

function runInstalled(fixture, script, args = [], extraEnv = {}) {
  return spawnSync("bash", [path.join(fixture.plugin, script), ...args], {
    env: { ...fixture.env, ...extraEnv },
    encoding: "utf8"
  });
}

test("install bootstraps a missing Attached CLI only after preflight", () => {
  const fixture = createFixture({ attached: false });
  fs.mkdirSync(path.dirname(fixture.bindings), { recursive: true });
  fs.writeFileSync(fixture.bindings, "-- BEGIN Attached session picker\n");

  const rejected = runInstalled(fixture, "install.sh");
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /partial or duplicate managed shortcut block/);
  assert.doesNotMatch(fs.readFileSync(fixture.log, "utf8"), /^curl /m);
  assert.equal(fs.existsSync(fixture.localBin), false);
  fs.unlinkSync(fixture.bindings);

  const failed = runInstalled(fixture, "install.sh", [], {
    ATTACHED_TEST_CURL_FAIL: "true"
  });
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /Could not install Attached/);
  assert.equal(fs.existsSync(fixture.localBin), false);
  assert.equal(fs.existsSync(fixture.bindings), false);
  assert.equal(fs.existsSync(fixture.providerConfig), false);

  const installed = runInstalled(fixture, "install.sh");
  assert.equal(installed.status, 0, installed.stderr);
  assert.match(installed.stdout, /Attached is not installed; installing it/);
  assert.equal(fs.statSync(path.join(fixture.localBin, "attached")).mode & 0o777, 0o755);
  assert.equal(fs.statSync(fixture.providerConfig).mode & 0o777, 0o600);
  assert.match(fs.readFileSync(fixture.bindings, "utf8"), /SUPER \+ CTRL \+ SHIFT \+ H/);

  const bootstrapCommands = fs.readFileSync(fixture.log, "utf8");
  assert.ok(
    bootstrapCommands.lastIndexOf("omarchy plugin validate")
      < bootstrapCommands.lastIndexOf("curl "),
    "checkout validation must finish before downloading Attached"
  );
  assert.ok(
    bootstrapCommands.lastIndexOf("curl ")
      < bootstrapCommands.lastIndexOf("omarchy-shell shell rescanPlugins"),
    "Attached must be available before plugin activation"
  );

  const repeated = runInstalled(fixture, "install.sh");
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.doesNotMatch(repeated.stdout, /installing it from/);

  const commands = fs.readFileSync(fixture.log, "utf8");
  assert.equal((commands.match(/^curl /gm) || []).length, 2);
  assert.match(
    commands,
    /curl --proto =https --tlsv1\.2 -LsSf https:\/\/install\.attached\.sh/
  );
});

test("install preserves user state and rolls back shell setup failures", () => {
  const fixture = createFixture();
  fs.mkdirSync(path.dirname(fixture.bindings), { recursive: true });
  const originalBindings = "-- existing user binding\n";
  fs.writeFileSync(fixture.bindings, originalBindings);

  for (const failedCommand of [
    "omarchy-shell shell rescanPlugins",
    `omarchy plugin enable ${pluginId}`
  ]) {
    const failed = runInstalled(fixture, "install.sh", [], {
      ATTACHED_TEST_FAIL_COMMAND: failedCommand
    });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /restored the previous bindings and provider configuration/);
    assert.equal(fs.readFileSync(fixture.bindings, "utf8"), originalBindings);
    assert.equal(fs.existsSync(fixture.providerConfig), false);
    assert.ok(fs.statSync(fixture.plugin).isDirectory());
  }

  const installed = runInstalled(fixture, "install.sh");
  assert.equal(installed.status, 0, installed.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(fixture.providerConfig, "utf8")), {
    encryptionPasswordProvider: "password"
  });
  const installedBindings = fs.readFileSync(fixture.bindings, "utf8");
  assert.equal((installedBindings.match(/BEGIN Attached session picker/g) || []).length, 1);

  fs.writeFileSync(
    fixture.providerConfig,
    '{"encryptionPasswordProvider":"1password","userSetting":true}\n'
  );
  const repeated = runInstalled(fixture, "install.sh");
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.equal(fs.readFileSync(fixture.bindings, "utf8"), installedBindings);
  assert.equal(
    fs.readFileSync(fixture.providerConfig, "utf8"),
    '{"encryptionPasswordProvider":"1password","userSetting":true}\n'
  );
  assert.doesNotMatch(fs.readFileSync(fixture.log, "utf8"), /^curl /m);

  const modifiedBindings = installedBindings.replace(
    '"Attached sessions"',
    '"My Attached sessions"'
  );
  fs.writeFileSync(fixture.bindings, modifiedBindings);
  const modified = runInstalled(fixture, "install.sh");
  assert.notEqual(modified.status, 0);
  assert.match(modified.stderr, /locally modified managed shortcut block/);
  assert.equal(fs.readFileSync(fixture.bindings, "utf8"), modifiedBindings);
});

test("install must run from the standard Omarchy checkout", () => {
  const fixture = createFixture();
  fs.rmSync(fixture.plugin, { recursive: true });
  const result = spawnSync("bash", [path.join(repository, "install.sh")], {
    env: fixture.env,
    encoding: "utf8"
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Install the plugin first with/);
  assert.equal(fs.existsSync(fixture.bindings), false);
  assert.equal(fs.existsSync(fixture.providerConfig), false);
});

test("uninstall restores its shortcut when plugin removal fails", () => {
  const fixture = createFixture();
  const installed = runInstalled(fixture, "install.sh");
  assert.equal(installed.status, 0, installed.stderr);
  const installedBindings = fs.readFileSync(fixture.bindings, "utf8");

  const failed = runInstalled(fixture, "uninstall.sh", [], {
    ATTACHED_TEST_FAIL_COMMAND: `omarchy plugin remove ${pluginId}`
  });
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /restored the Attached shortcut/);
  assert.equal(fs.readFileSync(fixture.bindings, "utf8"), installedBindings);
  assert.ok(fs.statSync(fixture.plugin).isDirectory());

  const removed = runInstalled(fixture, "uninstall.sh", ["--yes"]);
  assert.equal(removed.status, 0, removed.stderr);
  assert.equal(fs.existsSync(fixture.plugin), false);
  assert.doesNotMatch(fs.readFileSync(fixture.bindings, "utf8"), /Attached session picker/);
  assert.ok(fs.statSync(fixture.providerConfig).isFile());
  assert.ok(fs.statSync(path.join(fixture.bin, "attached")).isFile());
});
