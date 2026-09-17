# Real Safe Test Fixtures

These fixtures contain unchanged creation bytecode from the official published
Safe packages, not mock wallet implementations. The integration tests deploy
the singleton, proxy, version-matched `CompatibilityFallbackHandler`, `MultiSend`,
and `SignMessageLib` locally, initialize real owner thresholds, and use Safe's
actual signature validation and transaction execution paths.

| Safe version | Official package | Singleton / proxy names upstream |
| --- | --- | --- |
| 1.3.0 | `@gnosis.pm/safe-contracts@1.3.0` | `GnosisSafe` / `GnosisSafeProxy` |
| 1.4.1 | `@safe-global/safe-contracts@1.4.1` | `Safe` / `SafeProxy` |

The fixture filenames normalize the singleton and proxy names for a shared test
harness. The JSON retains the original `contractName` and `sourceName`, the
original artifact's SHA-256, and the package URL and SHA-512 integrity value.
Only the creation bytecode is used by tests; constructors run normally, including
the proxy's singleton initialization and MultiSend's immutable self-address.

Using published artifacts avoids recompiling old Safe sources with Mandate's
newer Solidity compiler. Tests need no RPC endpoint, fork, npm install, network
access, or Solidity compiler change. This matrix covers the ordinary Safe
singleton with its matching handler, not every historical handler combination,
SafeL2 singleton, custom module, guard, or contract-owner configuration.

## Run The Integration Tests

```sh
forge test --offline --match-contract 'FixedMandateSafe.*Test' -vv
```

The same 39 scenarios run against each version, for 78 tests in total. They also
run with the ordinary `forge test` command and in the existing CI job.

- All three opening routes and all four cancellation routes.
- SafeMessage wrapping, threshold enforcement, signature ordering, duplicate and
  unauthorized signers, wallet/chain/executor domains, owner rotation, and
  threshold changes.
- Real Safe transactions for direct calls, atomic token approval plus opening,
  and permissionless recurring pulls without further owner signatures.
- Missing-handler rejection and installation, onchain message approval with
  empty ERC-1271 signatures, and a self-billed approval/opening batch.
- Opening/cancellation nonce ownership, invalidation, replay, cancellation
  attribution, allowance revocation, and rollback after failed calls.
- Reverting Safe transactions versus successful outer calls that return an
  inner execution failure. Safe 1.4.1 indexes the failure event's transaction
  hash; Safe 1.3.0 does not. Both event layouts are asserted.

Only token behavior uses the repository's existing ERC-20 mock. Wallet code,
proxy forwarding, fallback handlers, signature verification, and MultiSend are
the real upstream contracts. Tests never impersonate a Safe with `vm.prank`.

## Reproduce And Verify

Node.js 18+ and `tar` are required only when refreshing or independently checking
the vendored artifacts. No npm dependencies or package lifecycle scripts run.

From the repository root:

```sh
node test/fixtures/safe/refresh.mjs --check
node test/fixtures/safe/refresh.mjs
```

The first command verifies every fixture and license against downloaded,
integrity-pinned official packages without changing the repository. The second
regenerates them. The script rejects any tarball that does not match the pinned
SHA-512 before reading any entries and extracts only explicitly named files.

Previously downloaded npm tarballs can be used without network access:

```sh
npm pack @gnosis.pm/safe-contracts@1.3.0 --ignore-scripts --pack-destination /tmp
npm pack @safe-global/safe-contracts@1.4.1 --ignore-scripts --pack-destination /tmp
node test/fixtures/safe/refresh.mjs --check --from /tmp
```

## Source And License

Safe's upstream source files identify their license as `LGPL-3.0-only`. Each
version directory includes the unmodified `LICENSE` distributed in its package.
The v1.3.0 npm package metadata says `GPL-3.0`, although its bundled source SPDX
headers and `LICENSE` identify LGPLv3; both are preserved upstream and no license
change is made here. These third-party fixtures are not relicensed under
Mandate's license.

Complete source and build artifacts are available in the exact integrity-pinned
packages referenced by each JSON's `sourceArchive`, and in the upstream releases:

- [Safe v1.3.0 source](https://github.com/safe-global/safe-smart-account/tree/v1.3.0)
- [Safe v1.4.1 source](https://github.com/safe-global/safe-smart-account/tree/v1.4.1)

The refresh script and local test harness remain separate from the upstream
contracts and do not modify their bytecode.
