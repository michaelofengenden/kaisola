// electron-builder afterPack hook: ad-hoc sign the packed .app.
// identity:null skips real signing, but a completely unsigned (or
// signature-broken) app downloaded from a browser gets Gatekeeper's
// "damaged and can't be opened" — no right-click → Open escape. An ad-hoc
// signature downgrades that to "unverified developer", which right-click →
// Open (or xattr -cr) gets past. Real fix later: Developer ID + notarization.
const { execSync } = require('node:child_process');
const path = require('node:path');

exports.default = async function adhocSign(context) {
  if (context.electronPlatformName !== 'darwin') return;
  const appPath = path.join(
    context.appOutDir,
    `${context.packager.appInfo.productFilename}.app`
  );
  const sh = (cmd) => execSync(cmd, { stdio: 'inherit' });
  // codesign refuses bundles containing Finder metadata ("resource fork,
  // Finder information, or similar detritus not allowed"). xattr -cr can't
  // remove the system-stamped com.apple.provenance, so strip by copying with
  // cp -X — and retry, because macOS can re-stamp the fresh copy mid-sign.
  const cleanBundle = () => {
    sh(`rm -rf "${appPath}.clean"`);
    sh(`cp -RX "${appPath}" "${appPath}.clean"`);
    sh(`rm -rf "${appPath}"`);
    sh(`mv "${appPath}.clean" "${appPath}"`);
    sh(`find "${appPath}" -name .DS_Store -delete`);
  };

  // Always clean once before electron-builder's real Developer ID signing.
  // Previously this hook returned before cleaning when CSC_NAME was present,
  // allowing FinderInfo copied from Electron's downloaded bundle to make the
  // release fail late in codesign.
  cleanBundle();
  if (process.env.CSC_LINK || process.env.CSC_NAME) return;

  let lastErr;
  for (let attempt = 1; attempt <= 3; attempt++) {
    if (attempt > 1) cleanBundle();
    try {
      sh(`codesign --force --deep --sign - "${appPath}"`);
      // no --strict: a late provenance re-stamp trips it, harmlessly
      sh(`codesign --verify --deep "${appPath}"`);
      return;
    } catch (err) {
      lastErr = err;
      console.warn(`adhoc-sign: attempt ${attempt} failed, retrying`);
    }
  }
  throw lastErr;
};
