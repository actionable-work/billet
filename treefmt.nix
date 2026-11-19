# Repository-wide formatting. Programs and priorities mirror the Bloomery
# workspace formatter so the test and example subflakes' own treefmt checks
# agree with this one; Prettier adds Markdown coverage.
{
  projectRootFile = "AGENTS.md";
  programs = {
    deadnix = {
      enable = true;
      priority = 0;
    };
    rustfmt = {
      enable = true;
      priority = 1;
    };
    shfmt = {
      enable = true;
      priority = 2;
    };
    toml-sort = {
      enable = true;
      priority = 3;
      all = true;
      # Requirement records keep their canonical field order through taplo.
      excludes = ["**/requirements/*.toml"];
    };
    yamlfmt = {
      enable = true;
      priority = 4;
    };
    alejandra = {
      enable = true;
      priority = 5;
    };
    shellcheck = {
      enable = true;
      priority = 6;
    };
    taplo = {
      enable = true;
      priority = 7;
    };
    prettier = {
      enable = true;
      priority = 8;
      includes = ["*.md"];
      settings.proseWrap = "always";
    };
  };
}
