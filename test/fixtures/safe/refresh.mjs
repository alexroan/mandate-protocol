import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const destination = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const check = args.includes("--check");
const fromIndex = args.indexOf("--from");
const from = fromIndex === -1 ? undefined : args[fromIndex + 1];
const recognized = new Set(["--check", "--from", from]);
if (args.some((arg) => !recognized.has(arg)) || (fromIndex !== -1 && (!from || from.startsWith("--")))) {
  throw new Error("Usage: node refresh.mjs [--check] [--from DIRECTORY]");
}

const releases = [
  {
    package: "@gnosis.pm/safe-contracts",
    version: "1.3.0",
    archive: "gnosis.pm-safe-contracts-1.3.0.tgz",
    integrity: "sha512-1p+1HwGvxGUVzVkFjNzglwHrLNA67U/axP0Ct85FzzH8yhGJb4t9jDjPYocVMzLorDoWAfKicGy1akPY9jXRVw==",
    contracts: {
      Safe: "GnosisSafe.sol/GnosisSafe",
      SafeProxy: "proxies/GnosisSafeProxy.sol/GnosisSafeProxy",
      CompatibilityFallbackHandler: "handler/CompatibilityFallbackHandler.sol/CompatibilityFallbackHandler",
      MultiSend: "libraries/MultiSend.sol/MultiSend",
      SignMessageLib: "examples/libraries/SignMessage.sol/SignMessageLib",
    },
  },
  {
    package: "@safe-global/safe-contracts",
    version: "1.4.1",
    archive: "safe-global-safe-contracts-1.4.1.tgz",
    integrity: "sha512-fP1jewywSwsIniM04NsqPyVRFKPMAuirC3ftA/TA4X3Zc5EnwQp/UCJUU2PL/37/z/jMo8UUaJ+pnFNWmMU7dQ==",
    contracts: {
      Safe: "Safe.sol/Safe",
      SafeProxy: "proxies/SafeProxy.sol/SafeProxy",
      CompatibilityFallbackHandler: "handler/CompatibilityFallbackHandler.sol/CompatibilityFallbackHandler",
      MultiSend: "libraries/MultiSend.sol/MultiSend",
      SignMessageLib: "libraries/SignMessageLib.sol/SignMessageLib",
    },
  },
];

function extract(archive, path) {
  return execFileSync("tar", ["-xOf", archive, `package/${path}`], { maxBuffer: 4 * 1024 * 1024 });
}

async function output(path, contents) {
  const expected = Buffer.from(contents);
  if (check) {
    const actual = await readFile(path);
    if (!actual.equals(expected)) throw new Error(`Fixture differs from pinned release: ${path}`);
  } else {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, expected);
  }
}

const temporary = await mkdtemp(join(tmpdir(), "mandate-safe-fixtures-"));
try {
  for (const release of releases) {
    const url = `https://registry.npmjs.org/${release.package}/-/safe-contracts-${release.version}.tgz`;
    let tarball;
    if (from) {
      tarball = await readFile(join(resolve(from), release.archive));
    } else {
      const response = await fetch(url, { signal: AbortSignal.timeout(30_000) });
      if (!response.ok) throw new Error(`Download failed (${response.status}): ${url}`);
      tarball = Buffer.from(await response.arrayBuffer());
    }
    const integrity = `sha512-${createHash("sha512").update(tarball).digest("base64")}`;
    if (integrity !== release.integrity) throw new Error(`Package integrity mismatch: ${release.package}`);
    const archive = join(temporary, release.archive);
    await writeFile(archive, tarball);
    const packageJson = JSON.parse(extract(archive, "package.json"));
    if (packageJson.name !== release.package || packageJson.version !== release.version) {
      throw new Error(`Unexpected package identity: ${release.package}`);
    }

    for (const [name, contractPath] of Object.entries(release.contracts)) {
      const artifactPath = `build/artifacts/contracts/${contractPath}.json`;
      const original = extract(archive, artifactPath);
      const artifact = JSON.parse(original);
      if (
        !/^0x(?:[0-9a-fA-F]{2})+$/.test(artifact.bytecode)
        || Object.keys(artifact.linkReferences).length !== 0
      ) {
        throw new Error(`Invalid or unlinked creation bytecode: ${artifactPath}`);
      }
      const fixture = {
        package: release.package,
        version: release.version,
        packageIntegrity: release.integrity,
        sourceArchive: url,
        artifactPath,
        artifactSha256: createHash("sha256").update(original).digest("hex"),
        sourceName: artifact.sourceName,
        contractName: artifact.contractName,
        bytecode: artifact.bytecode,
      };
      await output(join(destination, release.version, `${name}.json`), `${JSON.stringify(fixture, null, 2)}\n`);
    }
    await output(join(destination, release.version, "LICENSE"), extract(archive, "LICENSE"));
    console.log(`${check ? "Verified" : "Refreshed"} ${release.package}@${release.version}`);
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}
