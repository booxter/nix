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
    pandoc
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
    orgmode = {
      enable = true;
      settings = let
        orgdir = "~/.org";
      in
      {
        org_agenda_files = "${orgdir}/**/*";
        org_default_notes_file = "${orgdir}/notes.org";
        org_capture_templates = {
          J = {
            description = "Journal";
            template = "%<%H:%M> %?";
            target = "${orgdir}/journal/%<%Y>.org";
            datetree = true;
          };
        };
      };
    };
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
      name = "org-bullets";
      src = fetchFromGitHub {
          owner = "nvim-orgmode";
          repo = "org-bullets.nvim";
          rev = "46ae687e22192fb806b5977d664ec98af9cf74f6";
          sha256 = "sha256-cRcO0TDY0v9c/H5vQ1v96WiEkIhJDZkPcw+P58XNL9w=";
      };
    })
    (vimUtils.buildVimPlugin {
      name = "telescope-orgmode";
      src = fetchFromGitHub {
          owner = "nvim-orgmode";
          repo = "telescope-orgmode.nvim";
          rev = "2cd2ea778726c6e44429fef82f23b63197dbce1b";
          sha256 = "sha256-yeGdy1aip4TZKp++MuSo+kxo+XhFsOT0yv+9xJpKEps=";
      };
    })
    (vimUtils.buildVimPlugin {
      name = "org-roam";
      src = fetchFromGitHub {
          owner = "chipsenkbeil";
          repo = "org-roam.nvim";
          rev = "17f85abf207ece51bd37c8f3490d8f7d2fa106d0";
          sha256 = "sha256-gONxa/CUXPgV+ucC+WkEyeH/lFAiTaQx8bEBq7g6HyY=";
      };
    })
    (vimUtils.buildVimPlugin {
      name = "org-modern";
      src = fetchFromGitHub {
          owner = "danilshvalov";
          repo = "org-modern.nvim";
          rev = "c024900b7ee78a0274036025569b47001ef3e6aa";
          sha256 = "sha256-TYs3g5CZDVXCFXuYaj3IriJ4qlIOxQgArVOzT7pqkqs=";
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
    require('org-roam').setup({
      directory = "~/.org-roam"
    })

    require('org-bullets').setup()

    local Menu = require("org-modern.menu")
    require("orgmode").setup({
      ui = {
        menu = {
          handler = function(data)
            Menu:new({
              window = {
                margin = { 1, 0, 1, 0 },
                padding = { 0, 1, 0, 1 },
                title_pos = "center",
                border = "single",
                zindex = 1000,
              },
              icons = {
                separator = "➜",
              },
            }):open(data)
          end,
        },
      },
    })

    require('telescope').load_extension('orgmode')
  '';
  autoCmd = [
    {
      event = [ "FileType" ];
      pattern = [ "org" ];
      callback = {
        __raw = ''
          function()
            vim.keymap.set('n', '<leader>or', "")
            vim.keymap.set('n', '<leader>or', require('telescope').extensions.orgmode.refile_heading)
          end
        '';
      };
    }
  ];
}
