{ config, lib, pkgs, ... }:
{
  ###### interface

  options = {

    i18n = {
      glibcLocales = lib.mkOption {
        type = lib.types.path;
        default = pkgs.glibcLocales.override {
          allLocales = lib.any (x: x == "all") config.i18n.supportedLocales;
          locales = config.i18n.supportedLocales;
        };
        defaultText = lib.literalExpression ''
          pkgs.glibcLocales.override {
            allLocales = lib.any (x: x == "all") config.i18n.supportedLocales;
            locales = config.i18n.supportedLocales;
          }
        '';
        example = lib.literalExpression "pkgs.glibcLocales";
        description = ''
          Customized pkg.glibcLocales package.

          Changing this option can disable handling of i18n.defaultLocale
          and supportedLocale.
        '';
      };

      defaultLocale = lib.mkOption {
        type = lib.types.str;
        default = "en_US.UTF-8";
        example = "nl_NL.UTF-8";
        description = ''
          The default locale.  It determines the language for program
          messages, the format for dates and times, sort order, and so on.
          It also determines the character set, such as UTF-8.
        '';
      };

      extraLocaleSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = { LC_MESSAGES = "en_US.UTF-8"; LC_TIME = "de_DE.UTF-8"; };
        description = ''
          A set of additional system-wide locale settings other than
          `LANG` which can be configured with
          {option}`i18n.defaultLocale`.
        '';
      };

      supportedLocales = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.unique
          (builtins.map (l: (lib.replaceStrings [ "utf8" "utf-8" "UTF8" ] [ "UTF-8" "UTF-8" "UTF-8" ] l) + "/UTF-8") (
            [
              "C.UTF-8"
              "en_US.UTF-8"
              config.i18n.defaultLocale
            ] ++ (lib.attrValues (lib.filterAttrs (n: v: n != "LANGUAGE") config.i18n.extraLocaleSettings))
          ));
        defaultText = lib.literalExpression ''
          lib.unique
            (builtins.map (l: (lib.replaceStrings [ "utf8" "utf-8" "UTF8" ] [ "UTF-8" "UTF-8" "UTF-8" ] l) + "/UTF-8") (
              [
                "C.UTF-8"
                "en_US.UTF-8"
                config.i18n.defaultLocale
              ] ++ (lib.attrValues (lib.filterAttrs (n: v: n != "LANGUAGE") config.i18n.extraLocaleSettings))
            ))
        '';
        example = ["en_US.UTF-8/UTF-8" "nl_NL.UTF-8/UTF-8" "nl_NL/ISO-8859-1"];
        description = ''
          List of locales that the system should support.  The value
          `"all"` means that all locales supported by
          Glibc will be installed.  A full list of supported locales
          can be found at <https://sourceware.org/git/?p=glibc.git;a=blob;f=localedata/SUPPORTED>.
        '';
      };

    };

        fonts = {

      fontconfig = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            If enabled, a Fontconfig configuration file will be built
            pointing to a set of default fonts.  If you don't care about
            running X11 applications or any other program that uses
            Fontconfig, you can turn this option off and prevent a
            dependency on all those fonts.
          '';
        };

        confPackages = lib.mkOption {
          internal = true;
          type     = with lib.types; listOf path;
          default  = [ ];
          description = ''
            Fontconfig configuration packages.
          '';
        };

        antialias = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Enable font antialiasing. At high resolution (> 200 DPI),
            antialiasing has no visible effect; users of such displays may want
            to disable this option.
          '';
        };

        localConf = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = ''
            System-wide customization file contents, has higher priority than
            `defaultFonts` settings.
          '';
        };

        defaultFonts = {
          monospace = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["DejaVu Sans Mono"];
            description = ''
              System-wide default monospace font(s). Multiple fonts may be
              listed in case multiple languages must be supported.
            '';
          };

          sansSerif = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["DejaVu Sans"];
            description = ''
              System-wide default sans serif font(s). Multiple fonts may be
              listed in case multiple languages must be supported.
            '';
          };

          serif = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["DejaVu Serif"];
            description = ''
              System-wide default serif font(s). Multiple fonts may be listed
              in case multiple languages must be supported.
            '';
          };

          emoji = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["Noto Color Emoji"];
            description = ''
              System-wide default emoji font(s). Multiple fonts may be listed
              in case a font does not support all emoji.

              Note that fontconfig matches color emoji fonts preferentially,
              so if you want to use a black and white font while having
              a color font installed (eg. Noto Color Emoji installed alongside
              Noto Emoji), fontconfig will still choose the color font even
              when it is later in the list.
            '';
          };
        };

        hinting = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Enable font hinting. Hinting aligns glyphs to pixel boundaries to
              improve rendering sharpness at low resolution. At high resolution
              (> 200 dpi) hinting will do nothing (at best); users of such
              displays may want to disable this option.
            '';
          };

          autohint = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Enable the autohinter in place of the default interpreter.
              The results are usually lower quality than correctly-hinted
              fonts, but better than unhinted fonts.
            '';
          };

          style = lib.mkOption {
            type = lib.types.enum ["none" "slight" "medium" "full"];
            default = "slight";
            description = ''
              Hintstyle is the amount of font reshaping done to line up
              to the grid.

              slight will make the font more fuzzy to line up to the grid but
              will be better in retaining font shape, while full will be a
              crisp font that aligns well to the pixel grid but will lose a
              greater amount of font shape.
            '';
            apply =
              val:
              let
                from = "fonts.fontconfig.hinting.style";
                val' = lib.removePrefix "hint" val;
                warning = "The option `${from}` contains a deprecated value `${val}`. Use `${val'}` instead.";
              in
              lib.warnIf (lib.hasPrefix "hint" val) warning val';
          };
        };

        includeUserConf = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Include the user configuration from
            {file}`~/.config/fontconfig/fonts.conf` or
            {file}`~/.config/fontconfig/conf.d`.
          '';
        };

        subpixel = {

          rgba = lib.mkOption {
            default = "none";
            type = lib.types.enum ["rgb" "bgr" "vrgb" "vbgr" "none"];
            description = ''
              Subpixel order. The overwhelming majority of displays are
              `rgb` in their normal orientation. Select
              `vrgb` for mounting such a display 90 degrees
              clockwise from its normal orientation or `vbgr`
              for mounting 90 degrees counter-clockwise. Select
              `bgr` in the unlikely event of mounting 180
              degrees from the normal orientation. Reverse these directions in
              the improbable event that the display's native subpixel order is
              `bgr`.
            '';
          };

          lcdfilter = lib.mkOption {
            default = "default";
            type = lib.types.enum ["none" "default" "light" "legacy"];
            description = ''
              FreeType LCD filter. At high resolution (> 200 DPI), LCD filtering
              has no visible effect; users of such displays may want to select
              `none`.
            '';
          };

        };

        cache32Bit = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Generate system fonts cache for 32-bit applications.
          '';
        };

        allowBitmaps = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Allow bitmap fonts. Set to `false` to ban all
            bitmap fonts.
          '';
        };

        allowType1 = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Allow Type-1 fonts. Default is `false` because of
            poor rendering.
          '';
        };

        useEmbeddedBitmaps = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Use embedded bitmaps in fonts like Calibri.";
        };

      };

    };


  };


  ###### implementation

  config = {

    # environment.systemPackages =
    #   # We increase the priority a little, so that plain glibc in systemPackages can't win.
    #   lib.optional (config.i18n.supportedLocales != []) (lib.setPrio (-1) config.i18n.glibcLocales);

    # environment.sessionVariables =
    #   { LANG = config.i18n.defaultLocale;
    #     LOCALE_ARCHIVE = "/run/current-system/sw/lib/locale/locale-archive";
    #   } // config.i18n.extraLocaleSettings;

    # systemd.globalEnvironment = lib.mkIf (config.i18n.supportedLocales != []) {
    #   LOCALE_ARCHIVE = "${config.i18n.glibcLocales}/lib/locale/locale-archive";
    # };

    # # ‘/etc/locale.conf’ is used by systemd.
    # environment.etc."locale.conf".source = pkgs.writeText "locale.conf"
    #   ''
    #     LANG=${config.i18n.defaultLocale}
    #     ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "${n}=${v}") config.i18n.extraLocaleSettings)}
    #   '';

  };
}
