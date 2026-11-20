{
  description = "nix-devshell-cached-exports dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input, so the skill sources live only in THIS flake's lock and the root flake stays a leaf with zero skill inputs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # The builder lib; it carries no skill inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # skillspkgs' per-family skill combinations. It follows `nixpkgs` but not
    # `agent-skill-flake`, so its sources keep their own compatible builder.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "nix-devshell-cached-exports-skills";
      sources = [
        # The Nix tooling family's combination, and nothing beyond it: the
        # shell skills this Shell repository needs are already in it.
        { source = inputs.skillspkgs-combinations.combinations.nix-tooling; }
      ];
    };
}
