#!/usr/bin/env node
/**
 * Sign a HarmonyOS HAP with Huawei CBG debug materials.
 *
 * Decrypts DevEco ciphertext passwords using the official DecipherUtil
 * algorithm (material/ next to the .p12). Never prints secrets.
 *
 * Usage:
 *   node scripts/huawei-sign-hap.js \
 *     --in unsigned.hap --out signed.hap \
 *     --profile build-profile.json5 \
 *     --material-dir .runtime/huawei-cbg
 */
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
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
  // DevEco private profiles may use JSON or JSON5 spelling. Do not copy credentials into source.
  const safeKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = text.match(new RegExp("(?:[\"']?" + safeKey + "[\"']?)\\s*:\\s*([\"'])(.*?)\\1"));
  if (!m) throw new Error("missing " + key);
  return m[2];
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
  const inFile = arg("--in");
  const outFile = arg("--out");
  const materialDir = arg("--material-dir");
  const java = arg(
    "--java",
    "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java"
  );
  const jar = arg(
    "--jar",
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
  );
  const compatible = arg("--compatible-version", "23");
  if (process.env.TONGDAO_R1_PUBLISH !== "1") {
    throw new Error("huawei-sign-hap.js is not a publish entry; use scripts/r1-build.sh");
  }
  if (!profilePath || !inFile || !outFile || !materialDir) {
    throw new Error("usage: --profile --in --out --material-dir");
  }
  const permit = process.env.TONGDAO_SIGN_PERMIT || "";
  const ticket = process.env.TONGDAO_SIGN_TICKET || "";
  if (!permit || !fs.existsSync(permit)) {
    throw new Error("direct sign sealed; missing TONGDAO_SIGN_PERMIT");
  }
  if (!ticket || ticket.length < 32) {
    throw new Error("direct sign sealed; missing TONGDAO_SIGN_TICKET");
  }
  const permitParts = fs.readFileSync(permit, "utf8").trim().split(/\s+/);
  const wantHash = permitParts[0] || "";
  const wantTicket = permitParts[1] || "";
  const gotHash = crypto.createHash("sha256").update(fs.readFileSync(inFile)).digest("hex");
  if (!wantHash || wantHash !== gotHash) {
    throw new Error("sign permit hash mismatch");
  }
  if (wantTicket !== ticket) {
    throw new Error("sign permit ticket mismatch");
  }
  for (const p of [profilePath, inFile, java, jar, materialDir]) {
    if (!fs.existsSync(p)) throw new Error("missing " + p);
  }

  const text = fs.readFileSync(profilePath, "utf8");
  const localSigning = path.join(materialDir, "signing.json");
  const homeSigning = path.join(
    process.env.HOME || "",
    ".ohos/config/tongdao-signing.json"
  );
  let signing = null;
  for (const cand of [localSigning, homeSigning]) {
    if (fs.existsSync(cand)) {
      signing = JSON.parse(fs.readFileSync(cand, "utf8"));
      break;
    }
  }
  if (!signing || !signing.keyPassword || !signing.storePassword) {
    throw new Error(
      "signing credentials are not in git; place signing.json in material dir"
    );
  }
  const certName = signing.certpath || path.basename(grab(text, "certpath"));
  const profileName = signing.profile || path.basename(grab(text, "profile"));
  const storeName = signing.storeFile || path.basename(grab(text, "storeFile"));
  const cert = path.join(materialDir, path.basename(certName));
  const profile = path.join(materialDir, path.basename(profileName));
  const store = path.join(materialDir, path.basename(storeName));
  const alias = signing.keyAlias || grab(text, "keyAlias");
  const alg = signing.signAlg || grab(text, "signAlg");
  for (const p of [cert, profile, store]) {
    if (!fs.existsSync(p)) throw new Error("missing " + p);
  }

  const keyPwd = String(signing.keyPassword);
  const storePwd = String(signing.storePassword);
  if (!keyPwd || !storePwd) throw new Error("signing.json produced empty password");
  try {
    fs.chmodSync(store, 0o600);
  } catch (e) {
    // best-effort
  }

  const args = [
    "-jar",
    jar,
    "sign-app",
    "-mode",
    "localSign",
    "-keyAlias",
    alias,
    "-appCertFile",
    cert,
    "-profileFile",
    profile,
    "-inFile",
    inFile,
    "-signAlg",
    alg,
    "-keystoreFile",
    store,
    "-outFile",
    outFile,
    "-compatibleVersion",
    compatible,
    "-signCode",
    "1",
    "-pwdInputMode",
    "1",
  ];
  process.stderr.write("signing " + inFile + "\n");
  const ptyPy =
    "import os,pty,select,sys\n" +
    "pw=sys.stdin.read()\n" +
    "cmd=sys.argv[1:]\n" +
    "pid,fd=pty.fork()\n" +
    "if pid==0:\n" +
    "    os.execvp(cmd[0], cmd)\n" +
    "os.write(fd, pw.encode('utf-8'))\n" +
    "while True:\n" +
    "    ready,_,_=select.select([fd],[],[],180)\n" +
    "    if not ready:\n" +
    "        break\n" +
    "    try:\n" +
    "        data=os.read(fd,8192)\n" +
    "    except OSError:\n" +
    "        break\n" +
    "    if not data:\n" +
    "        break\n" +
    "    sys.stdout.buffer.write(data)\n" +
    "    sys.stdout.buffer.flush()\n" +
    "_,status=os.waitpid(pid,0)\n" +
    "sys.exit(os.waitstatus_to_exitcode(status))\n";
  const result = spawnSync("python3", ["-c", ptyPy, java, ...args], {
    encoding: "utf8",
    input: storePwd + "\n" + keyPwd + "\n",
  });
  const redact = (s) =>
    (s || "").split(keyPwd).join("***").split(storePwd).join("***");
  process.stdout.write(redact(result.stdout));
  process.stderr.write(redact(result.stderr || ""));
  if (result.status !== 0) {
    process.exit(result.status || 1);
  }
  process.stderr.write("signed " + outFile + " size=" + fs.statSync(outFile).size + "\n");
}

main();
