// Copies what Tauri buries in target/release/bundle/ into windows/release/, with
// the names it ships under. Used by `npm run pack` and by the release workflows,
// so both produce exactly the same file names.
//
//   Windows  Coucou-Windows-<v>-setup.exe
//   Linux    Coucou-Linux-<v>-<arch>.deb / .AppImage / .tar.gz
//
// Every file also gets a copy without the version, for the rolling
// `windows-latest` / `linux-latest` releases.

import { readFileSync, mkdirSync, copyFileSync, readdirSync, statSync, rmSync, chmodSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const release = join(root, "target", "release");
const outDir = join(root, "release");

const { version } = JSON.parse(readFileSync(join(root, "src-tauri", "tauri.conf.json"), "utf8"));

/** The newest file in `dir` whose name passes `match`, or exit with a hint. */
function newest(dir, match, what) {
  let files = [];
  try {
    files = readdirSync(dir).filter(match);
  } catch {}
  if (files.length === 0) {
    console.error(`No ${what} in ${dir} — run \`npm run tauri build\` first.`);
    process.exit(1);
  }
  // Newest wins, in case an older build is still lying around.
  return files
    .map((f) => join(dir, f))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
}

const shipped = [];

/** Copies `src` to `<name>` and to its rolling, version-less twin. */
function ship(src, versioned, rolling) {
  for (const name of [versioned, rolling]) {
    const dest = join(outDir, name);
    copyFileSync(src, dest);
    shipped.push(dest);
  }
}

mkdirSync(outDir, { recursive: true });

if (process.platform === "win32") {
  const exe = newest(join(release, "bundle", "nsis"), (f) => f.endsWith("-setup.exe"), "installer");
  ship(exe, `Coucou-Windows-${version}-setup.exe`, "Coucou-Windows-setup.exe");
} else if (process.platform === "linux") {
  // Debian and AppImage spell the architecture differently; keep each file's
  // own convention so package managers and users both recognise it.
  const deb = { x64: "amd64", arm64: "arm64" }[process.arch] ?? process.arch;
  const gnu = { x64: "x86_64", arm64: "aarch64" }[process.arch] ?? process.arch;

  const debFile = newest(join(release, "bundle", "deb"), (f) => f.endsWith(".deb"), ".deb package");
  ship(debFile, `Coucou-Linux-${version}-${deb}.deb`, `Coucou-Linux-${deb}.deb`);

  const appImage = newest(join(release, "bundle", "appimage"), (f) => f.endsWith(".AppImage"), "AppImage");
  ship(appImage, `Coucou-Linux-${version}-${gnu}.AppImage`, `Coucou-Linux-${gnu}.AppImage`);
  for (const f of shipped) if (f.endsWith(".AppImage")) chmodSync(f, 0o755);

  // The tarball is the plain binaries plus a per-user install script, for
  // distributions that take neither a .deb nor an AppImage.
  const name = `coucou-${version}-linux-${gnu}`;
  const stage = join(outDir, name);
  rmSync(stage, { recursive: true, force: true });
  mkdirSync(join(stage, "icons"), { recursive: true });
  copyFileSync(join(release, "coucou"), join(stage, "coucou"));
  copyFileSync(join(release, "coucou-hook"), join(stage, "coucou-hook"));
  chmodSync(join(stage, "coucou"), 0o755);
  chmodSync(join(stage, "coucou-hook"), 0o755);
  const icons = join(root, "src-tauri", "icons");
  for (const [src, size] of [
    ["32x32.png", "32x32"],
    ["128x128.png", "128x128"],
    ["128x128@2x.png", "256x256"],
    ["icon.png", "512x512"],
  ]) {
    copyFileSync(join(icons, src), join(stage, "icons", `${size}.png`));
  }
  for (const f of ["install.sh", "coucou.desktop", "README.txt"]) {
    copyFileSync(join(root, "linux", f), join(stage, f));
  }
  chmodSync(join(stage, "install.sh"), 0o755);
  copyFileSync(join(root, "..", "LICENSE"), join(stage, "LICENSE"));
  copyFileSync(join(root, "..", "LICENSE-ASSETS.md"), join(stage, "LICENSE-ASSETS.md"));

  const tarball = join(outDir, `Coucou-Linux-${version}-${gnu}.tar.gz`);
  execFileSync("tar", ["-czf", tarball, "--owner=0", "--group=0", "-C", outDir, name], { stdio: "inherit" });
  rmSync(stage, { recursive: true, force: true });
  shipped.push(tarball);
  const rolling = join(outDir, `Coucou-Linux-${gnu}.tar.gz`);
  copyFileSync(tarball, rolling);
  shipped.push(rolling);
} else {
  console.error(`Nothing to pack on ${process.platform}.`);
  process.exit(1);
}

console.log("");
for (const f of shipped) {
  const mb = (statSync(f).size / 1024 / 1024).toFixed(2);
  console.log(`  ${mb.padStart(7)} MB  ${f}`);
}
console.log("");
