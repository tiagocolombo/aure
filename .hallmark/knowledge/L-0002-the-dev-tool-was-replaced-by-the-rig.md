---
id: L-0002
kind: map
scope: ["flake.nix", "flake.lock", "rig.toml"]
lens: repo_rules
source: ["H-0001"]
status: proposed
used: 0
---
# The dev tool was replaced by the rig tool: flake.nix takes rig as a flake input and calls rig.lib.mkProject with ./rig.toml.

The project config is rig.toml, formerly dev.toml, and flake.nix builds the project with rig.lib.mkProject. The rig input points at git+ssh://git@github.com/tiagocolombo/rig and follows rig/nixpkgs. flake.lock pins rig at commit 58c1733. The .dev/ state directory and the Doppler configs named dev were deliberately kept, so a reviewer should not flag them as leftover dev references.
