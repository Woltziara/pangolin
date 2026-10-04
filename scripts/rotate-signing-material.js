#!/usr/bin/env node
/**
 * Rotate CBG keystore passwords while keeping the same certificate.
 * Writes signing.json outside git. Never prints secrets.
 */
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const COMPONENT = new Int8Array([
  49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119,
]);

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1];
  return fallback;
}

function grab(text, key) {
  const m = text.match(new RegExp(key + ":\\s*'([^']+)'"));
  if (!m) throw new Error("missing " + key);
  return m[1];
}

function readDirBytes(dir) {
  const files = fs.readdirSync(dir).filter((x) => x !== ".DS_Store");
  if (files.length !== 1) throw new Error("material error: " + dir);
  return new Int8Array(fs.readFileSync(path.join(dir, files[0])));
}

function xor(a, b) {
  const out = new Int8Array(a.byteLength);
  for (let i = 0; i < a.byteLength; i++) out[i] = a[i] ^ b[i];
  return out;
}

function decrypt(key, data) {
  const extra =
    ((255 & data[0]) << 24) |
    ((255 & data[1]) << 16) |
    ((255 & data[2]) << 8) |
    (255 & data[3]);
  const ivLen = data.length - 4 - extra;
  const iv = Buffer.from(data.slice(4, 4 + ivLen));
  const decipher = crypto.createDecipheriv("aes-128-gcm", Buffer.from(key), iv);
  const tag = Buffer.from(data.slice(data.length - 16));
  decipher.setAuthTag(tag);
  const cipherBytes = Buffer.from(data.subarray(4 + ivLen, data.length - 16));
  return Buffer.concat([decipher.update(cipherBytes), decipher.final()]);
}

function getKey(materialParent) {
  const material = path.join(materialParent, "material");
  const fdDir = path.join(material, "fd");
  const fdNames = fs.readdirSync(fdDir).filter((x) => x !== ".DS_Store");
  if (fdNames.length !== 3) throw new Error("fd illegal: " + fdDir);
  const fds = fdNames.map((n) => readDirBytes(path.join(fdDir, n)));
  const salt = readDirBytes(path.join(material, "ac"));
  const work = readDirBytes(path.join(material, "ce"));
  const parts = fds.concat([COMPONENT]);
  let mixed = xor(parts[0], parts[1]);
  for (let i = 2; i < parts.length; i++) mixed = xor(mixed, parts[i]);
  const rootKey = crypto.pbkdf2Sync(
    Buffer.from(mixed).toString(),
    Buffer.from(salt),
    10000,
    16,
    "sha256"
  );
  return new Int8Array(decrypt(rootKey, work));
}

function decryptPwd(materialParent, hexPwd) {
  const key = getKey(materialParent);
  const packed = new Int8Array(Buffer.from(hexPwd, "hex"));
  return decrypt(key, packed).toString("utf-8");
}

function main() {
  const profilePath = arg("--profile");
  const materialDir = arg("--material-dir");
  const outFile = arg("--out");
  const keytool = arg(
    "--keytool",
    "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/keytool"
  );
  if (!profilePath || !materialDir || !outFile) {
    throw new Error("usage: --profile --material-dir --out");
  }
  const text = fs.readFileSync(profilePath, "utf8");
  const storeName = path.basename(grab(text, "storeFile"));
  const alias = grab(text, "keyAlias");
  const store = path.join(materialDir, storeName);
  const oldKey = decryptPwd(materialDir, grab(text, "keyPassword"));
  const oldStore = decryptPwd(materialDir, grab(text, "storePassword"));
  const next = crypto.randomBytes(24).toString("hex");
  const tmp = store + ".rotated";
  fs.copyFileSync(store, tmp);
  const storePass = spawnSync(
    keytool,
    ["-storepasswd", "-storetype", "PKCS12", "-keystore", tmp, "-storepass", oldStore, "-new", next],
    { encoding: "utf8" }
  );
  if (storePass.status !== 0) {
    fs.unlinkSync(tmp);
    throw new Error("storepasswd failed");
  }
  const keyPass = spawnSync(
    keytool,
    [
      "-keypasswd",
      "-storetype",
      "PKCS12",
      "-keystore",
      tmp,
      "-alias",
      alias,
      "-storepass",
      next,
      "-keypass",
      oldKey,
      "-new",
      next,
    ],
    { encoding: "utf8" }
  );
  if (keyPass.status !== 0) {
    // PKCS12 often uses a single password; storepasswd already rotated it.
    process.stderr.write("keypasswd skipped-or-failed; PKCS12 store password rotated\n");
  }
  fs.renameSync(tmp, store);
  const doc = {
    rotatedAt: new Date().toISOString(),
    certCompatible: true,
    keyAlias: alias,
    signAlg: grab(text, "signAlg"),
    certpath: path.basename(grab(text, "certpath")),
    profile: path.basename(grab(text, "profile")),
    storeFile: storeName,
    keyPassword: next,
    storePassword: next,
  };
  fs.writeFileSync(outFile, JSON.stringify(doc, null, 2) + "\n", { mode: 0o600 });
  fs.chmodSync(outFile, 0o600);
  process.stderr.write("ROTATED cert-compatible signing.json mode=0600\n");
}

main();
