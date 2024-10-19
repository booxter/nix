{ pkgs, ...}: with pkgs; {
  enable = true;
  defaultEditor = true;
  # TODO: introduce an alias for view (nvim -R)
  viAlias = true;
  vimAlias = true;
  vimdiffAlias = true;
  colorschemes.gruvbox.enable = true;
  clipboard.register = "unnamedplus";
  extraPackages = [
    golangci-lint
    ripgrep
  ];
  plugins = {
    lualine.enable = true;
    lsp = {
      enable = true;
      servers = {
        ansiblels.enable = true;
        # disable until shellcheck no longer ooms the machine: https://github.com/koalaman/shellcheck/issues/2721
        bashls.enable = false;
        dockerls.enable = true;
        golangci_lint_ls.enable = true;
        gopls.enable = true;
        html.enable = true;
        jsonls.enable = true;
        lua_ls.enable = true;
        marksman.enable = true; # markdown
        nil_ls.enable = true; # nix
        nixd.enable = true; # nix
        perlpls.enable = true;
        pyright.enable = true; # python
        sqls.enable = true; # SQL
        taplo.enable = true; # toml
        yamlls.enable = true; # toml

        clangd.enable = true;
        clangd.extraOptions.capabilities.offsetEncoding = "utf-16";
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
    telescope = {
      enable = true;
      extensions = {
        file-browser.enable = true;
        undo.enable = true;
      };
    };
    toggleterm.enable = true;
    web-devicons.enable = true;
  };
  extraPlugins = with vimPlugins; [
    nerdtree
    vim-polyglot
    vimux
    (vimUtils.buildVimPlugin {
      name = "my-plugin";
      src = fetchFromGitHub {
          owner = "nvim-focus";
          repo = "focus.nvim";
          rev = "3841a38df972534567e85840d7ead20d3a26faa6";
          hash = "sha256-mgHk4u0ab2uSUNE+7DU22IO/xS5uop9iATfFRk6l6hs=";
      };
    })
  ];
  extraConfigVim = ''
    " Show relative except for current line
    set number
    set relativenumber

    " Vimux runner mappings
    " \vp for command prompt
    map <Leader>vp :VimuxPromptCommand<CR>
    " \vl to run latest command
    map <Leader>vl :VimuxRunLastCommand<CR>
  '';
  extraConfigLua = ''
    require('focus').setup()
  '';
}
