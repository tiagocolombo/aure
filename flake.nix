{
  description = "Development shell — everything is declared in rig.toml";

  # SSH, not github:owner/repo — the repository is private and Nix's GitHub
  # fetcher calls the API unauthenticated, so it would 404. This uses the
  # SSH key git already has.
  inputs.rig.url = "git+ssh://git@github.com/tiagocolombo/rig";
  # `nix develop` takes bashInteractive from the top-level `nixpkgs` input.
  # Without this it falls back to the registry's nixpkgs-unstable, which has
  # dropped x86_64-darwin, and then to macOS bash 3.2, which breaks the shell.
  inputs.nixpkgs.follows = "rig/nixpkgs";

  outputs = { rig, ... }: rig.lib.mkProject ./rig.toml;
}
