{ pkgs, ...}: {
  enable = true;
  defaultEditor = true;
  viAlias = true;
  vimAlias = true;
  vimdiffAlias = true;
  colorschemes.gruvbox.enable = true;
  clipboard.register = "unnamedplus";
  plugins = {
    lualine.enable = true;
    lsp = {
      enable = true;
      servers = {
        ansiblels.enable = true;
        bashls.enable = true;
        clangd.enable = true;
        dockerls.enable = true;
        golangci-lint-ls.enable = true;
        gopls.enable = true;
        html.enable = true;
        jsonls.enable = true;
        lua-ls.enable = true;
        marksman.enable = true; # markdown
        nil-ls.enable = true; # nix
        perlpls.enable = true;
        pyright.enable = true; # python
        sqls.enable = true; # SQL
        taplo.enable = true; # toml
        yamlls.enable = true; # toml
      };
    };
    cmp = {
      enable = true;
      autoEnableSources = true;
    };
    cmp-async-path.enable = true;
    cmp-buffer.enable = true;
    cmp-cmdline.enable = true;
    cmp-cmdline-history.enable = true;
    cmp-conventionalcommits.enable = true;
    cmp-git.enable = true;
    cmp-nvim-lsp.enable = true;
    cmp-nvim-lsp-signature-help.enable = true;
    cmp-tmux.enable = true;
    cmp-treesitter.enable = true;
    cmp-zsh.enable = true;
    copilot-vim = {
      enable = true;
      settings.workspace_folders = [ "~/src" ];
    };
    fugitive.enable = true;
    gitsigns.enable = true;
    tmux-navigator.enable = true;
    toggleterm.enable = true;
  };
  extraPlugins = [
    pkgs.vimPlugins.nerdtree
    pkgs.vimPlugins.vim-polyglot
    (pkgs.vimUtils.buildVimPlugin {
      name = "my-plugin";
      src = pkgs.fetchFromGitHub {
          owner = "nvim-focus";
          repo = "focus.nvim";
          rev = "3841a38df972534567e85840d7ead20d3a26faa6";
          hash = "sha256-mgHk4u0ab2uSUNE+7DU22IO/xS5uop9iATfFRk6l6hs=";
      };
    })
  ];
  extraConfigLua = ''
    require('focus').setup()
  '';
}
