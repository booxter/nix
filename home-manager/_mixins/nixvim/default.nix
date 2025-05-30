{ pkgs, ... }:
{
  programs.nixvim = {
    enable = true;
    nixpkgs.config.allowUnfree = true;

    defaultEditor = true;

    # alias to nixvim
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;

    colorschemes.gruvbox.enable = true;

    # copy to system clipboard
    clipboard.register = "unnamedplus";

    # some dependencies
    extraPackages = with pkgs; [
      ansible
      ansible-lint
      golangci-lint
      ripgrep
    ];

    diagnostic.settings = {
      virtual_lines = false;
      virtual_text = true;
    };

    plugins = {
      lualine.enable = true;
      lsp = {
        enable = true;
        servers = {
          ansiblels.enable = true;
          # disable until shellcheck no longer ooms:
          # https://github.com/koalaman/shellcheck/issues/2721
          # bashls.enable = true;
          dockerls.enable = true;
          golangci_lint_ls.enable = true;
          gopls.enable = true;
          html.enable = true;
          jsonls.enable = true;
          lua_ls.enable = true;
          marksman.enable = true; # markdown
          nil_ls = {
            enable = true; # nix
            settings.nix.flake.autoArchive = true;
          };
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
      lsp-lines.enable = true;

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

    extraPlugins = with pkgs.vimPlugins; [
      nerdtree
      vim-polyglot
      vimux
    ];

    keymaps = [
      {
        key = "<Leader>l";
        action = "<CMD>lua require('lsp_lines').toggle()<CR><CMD>set diagnostic.settings.virtual_text!<CR>";
      }
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
  };
}
