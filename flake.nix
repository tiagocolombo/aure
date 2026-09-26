{
  description = "dev shell — everything is declared in dev.toml";

  # SSH, not github:owner/repo — the repository is private and Nix's GitHub
  # fetcher calls the API unauthenticated, so it would 404. This uses the
  # SSH key git already has.
  inputs.dev.url = "git+ssh://git@github.com/tiagocolombo/dev";
  # `nix develop` takes bashInteractive from the top-level `nixpkgs` input.
  # Without this it falls back to the registry's nixpkgs-unstable, which has
  # dropped x86_64-darwin, and then to macOS bash 3.2, which breaks the shell.
  inputs.nixpkgs.follows = "dev/nixpkgs";

  outputs = { dev, ... }: dev.lib.mkProject ./dev.toml;
}
