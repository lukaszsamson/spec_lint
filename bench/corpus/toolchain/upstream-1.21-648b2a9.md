# Upstream Elixir 1.21 at 648b2a9: build and qualification toolchain

SpecLint's compiler adapter (`SpecLint.Compiler.V121`) is qualified for two
Elixir revisions: the fork revision `c24c235` it was developed on, and the
unmodified upstream revision described here. The upstream build needs
nothing from the fork.

| | |
| --- | --- |
| Repository | `https://github.com/elixir-lang/elixir` |
| Revision | `648b2a94934664cfd2c788348d02d799c68faa69` ("Preserve left element types in list subtraction (#15808)", 2026-09-27 16:36:51 UTC, upstream `main`) |
| Tree | `a9514de812562d32924668ec53aee240fa676b11` |
| Version | `1.21.0-dev`, `System.build_info()[:revision]` `648b2a9` |
| Adapter id | `1.21.0-dev+648b2a9` |
| Checker chunk | `elixir_checker_v10` |
| Erlang/OTP | 28 (`OTP_VERSION` 28.5.0.1, erts 16.4.0.1) |
| `SOURCE_DATE_EPOCH` | `1790527011` (the commit time; `System.build_info()[:date]` `2026-09-27T16:36:51Z`) |

The audit of every internal SpecLint uses, against `c24c235`, is
`audit-648b2a9.md` in this directory.

## Building from a clean machine

```sh
bench/corpus/toolchain/build_elixir.sh 648b2a94934664cfd2c788348d02d799c68faa69 /path/to/elixir-648b2a9
```

`build_elixir.sh REV DEST` needs `git`, `make` and Erlang/OTP 28 (`erl` on
`PATH`; `SPEC_LINT_OTP_RELEASE` changes the required release). It
initialises `DEST`, fetches only `REV` from the upstream repository
(`ELIXIR_REPO` overrides it), checks it out detached, verifies `HEAD`, sets
`SOURCE_DATE_EPOCH` to the commit time, runs `make compile`, refuses a build
that leaves the checkout dirty, and prints the build identity
(`identity.exs`) as JSON.

The identity is path independent. BEAM files of the same revision built in
two directories differ: debug info, and the literals of about 25 modules,
record the build directory. `identity.exs` hashes, per module, the code,
atom, string, import and export chunks and the literal table with the build
root replaced by `$ROOT` (`code_digest`), and the decoded `ExCk` chunk
serialised with `:deterministic` (`exck_digest`; the raw chunk bytes are not
deterministic).

### Result (2026-09-29)

Built twice, both with `SOURCE_DATE_EPOCH=1790527011` and OTP 28.5.0.1:

1. as a worktree of an existing checkout (`git -C ~/elixir worktree add
   DEST 648b2a94934664cfd2c788348d02d799c68faa69 --detach`, then
   `make compile` in `DEST`): 32 s;
2. from a fresh clone with `build_elixir.sh`, run under `env -i` with only
   `HOME`, `LANG` and a `PATH` of the OTP installation and the system
   directories (no Elixir, no asdf shims): 36 to 42 s including the fetch.

Both produced the same identity:

```json
{
  "build_date": "2026-09-27T16:36:51Z",
  "checker_version": "elixir_checker_v10",
  "code_digest": "bb1eb6ffb87c526cf1eb3e588759e18845f5557d41e0d05308e92ebf45fa116f",
  "elixir_version": "1.21.0-dev",
  "exck_digest": "2166532d21874b8814974360b4ff482e530f7a00d155fbad8da28e3da7829a39",
  "module_types_beam_lib_md5": "ddee27c09a98c65a1cb1dfe96b223a51",
  "modules": 447,
  "otp_release": "28",
  "otp_version": "28.5.0.1",
  "revision": "648b2a9"
}
```

For comparison, the fork build `c24c235` (`~/elixir`) has `code_digest`
`19cf9a66a58e18754888e643131736c3d84dcadbe2e91f5c6cd2c43d75403def` and
`exck_digest` `80f75ead4439f7cbf958b3fe8b94577dce636a01826aec0fd9cfce26394b22a2`
(its build date is its own commit time, so the System module differs too).

## Using it

Select the build by putting it first on `PATH`, and keep its build
artifacts apart from the default `_build` (both compilers are
`1.21.0-dev`, so Mix and Dialyxir would otherwise reuse each other's files):

```sh
export PATH=/path/to/elixir-648b2a9/bin:$PATH
export MIX_BUILD_PATH=/path/to/build-648b2a9/test   # one per MIX_ENV
MIX_ENV=test mix test

export MIX_BUILD_PATH=/path/to/build-648b2a9/dev
export SPEC_LINT_PLT_DIR=/path/to/plts-648b2a9      # mix.exs reads it
mix dialyzer
```

With asdf, `ASDF_ELIXIR_VERSION=path:/path/to/elixir-648b2a9` selects it
as well. The consumer integration tests start `mix` in fixture projects;
`SpecLint.ProjectFixture` clears `MIX_BUILD_PATH` for them, so the fixtures
build into their own directories with the compiler on `PATH`.

## Corpora under the upstream compiler

`compile_corpora.sh` recompiles corpus checkouts with a given build into
separate build paths (`MIX_BUILD_PATH=$SPEC_LINT_CORPUS_BUILD/NAME`),
refusing a checkout that is dirty before or after, and `run.sh` reads them
from there when `SPEC_LINT_CORPUS_BUILD` is set (paths are written as
`$BUILD`). `upstream-648b2a9.json` is the corpus manifest for the replay:
`expansion.json` plus the stdlib at `648b2a9`. The replay commands and
results are in `../reports/upstream-648b2a9/README.md`.
