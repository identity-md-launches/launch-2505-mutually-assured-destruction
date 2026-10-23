# Vendored dependencies

Dependencies are ordinary files, not submodules. Their contents are pinned by `DEPENDENCIES.sha256`; builds do not fetch packages.

| Dependency | Release and source | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | [v5.4.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.4.0) | ERC20, IERC20, IERC20Metadata, Context, draft-IERC6093, and license | MIT |
| Forge Standard Library | [v1.9.4](https://github.com/foundry-rs/forge-std/tree/v1.9.4) | `src/` and both license files | MIT or Apache-2.0 |

OpenZeppelin files were downloaded unchanged from the release's `raw.githubusercontent.com` paths. Forge Standard Library source and license files were copied unchanged from the release archive at `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.4`. Unneeded upstream tests, configuration, documentation, and development tools are excluded.

Only the five OpenZeppelin Solidity files are dependencies of the production token. Forge Standard Library is a test dependency. License notices are retained under each dependency directory.

To verify the vendored bytes locally:

```sh
sha256sum --check DEPENDENCIES.sha256
```
