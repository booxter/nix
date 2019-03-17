# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  boot.initrd = {
    # Root LVM volume is encrypted.
    luks.devices = [
      {
        name = "root";
        device = "/dev/sda1";
        preLVM = true;
      }
    ];
    # Support Microsoft keyboard on stage1 to enter disk password.
    kernelModules = [ "hid_microsoft" ];
  };
  boot.cleanTmpDir = true;

  networking = {
    hostName = "dell"; # Define your hostname.
    extraHosts = ''
      ::1 dell
      127.0.0.1 dell
    '';
    networkmanager = {
      enable = true;
      packages = [ pkgs."networkmanager-openvpn" ];
    };
  };

  krb5 = {
    enable = true;
    kerberos = pkgs.heimdalFull;
    libdefaults = {
      default_realm = "REDHAT.COM";
      dns_lookup_realm = false;
      ticket_lifetime = "24h";
      renew_lifetime = "7d";
      forwardable = true;
      rdns = false;
    };
    realms = {
      "REDHAT.COM" = {
        admin_server = "kerberos.corp.redhat.com";
        kdc = "kerberos.corp.redhat.com";
      };
    };
    domain_realm = {
      "redhat.com" = "REDHAT.COM";
      ".redhat.com" = "REDHAT.COM";
    };
  };

  environment.etc."pki/tls/certs/2015-RH-IT-Root-CA.pem".text = ''
-----BEGIN CERTIFICATE-----
MIIENDCCAxygAwIBAgIJANunI0D662cnMA0GCSqGSIb3DQEBCwUAMIGlMQswCQYD
VQQGEwJVUzEXMBUGA1UECAwOTm9ydGggQ2Fyb2xpbmExEDAOBgNVBAcMB1JhbGVp
Z2gxFjAUBgNVBAoMDVJlZCBIYXQsIEluYy4xEzARBgNVBAsMClJlZCBIYXQgSVQx
GzAZBgNVBAMMElJlZCBIYXQgSVQgUm9vdCBDQTEhMB8GCSqGSIb3DQEJARYSaW5m
b3NlY0ByZWRoYXQuY29tMCAXDTE1MDcwNjE3MzgxMVoYDzIwNTUwNjI2MTczODEx
WjCBpTELMAkGA1UEBhMCVVMxFzAVBgNVBAgMDk5vcnRoIENhcm9saW5hMRAwDgYD
VQQHDAdSYWxlaWdoMRYwFAYDVQQKDA1SZWQgSGF0LCBJbmMuMRMwEQYDVQQLDApS
ZWQgSGF0IElUMRswGQYDVQQDDBJSZWQgSGF0IElUIFJvb3QgQ0ExITAfBgkqhkiG
9w0BCQEWEmluZm9zZWNAcmVkaGF0LmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEP
ADCCAQoCggEBALQt9OJQh6GC5LT1g80qNh0u50BQ4sZ/yZ8aETxt+5lnPVX6MHKz
bfwI6nO1aMG6j9bSw+6UUyPBHP796+FT/pTS+K0wsDV7c9XvHoxJBJJU38cdLkI2
c/i7lDqTfTcfLL2nyUBd2fQDk1B0fxrskhGIIZ3ifP1Ps4ltTkv8hRSob3VtNqSo
GxkKfvD2PKjTPxDPWYyruy9irLZioMffi3i/gCut0ZWtAyO3MVH5qWF/enKwgPES
X9po+TdCvRB/RUObBaM761EcrLSM1GqHNueSfqnho3AjLQ6dBnPWlo638Zm1VebK
BELyhkLWMSFkKwDmne0jQ02Y4g075vCKvCsCAwEAAaNjMGEwHQYDVR0OBBYEFH7R
4yC+UehIIPeuL8Zqw3PzbgcZMB8GA1UdIwQYMBaAFH7R4yC+UehIIPeuL8Zqw3Pz
bgcZMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEB
CwUAA4IBAQBDNvD2Vm9sA5A9AlOJR8+en5Xz9hXcxJB5phxcZQ8jFoG04Vshvd0e
LEnUrMcfFgIZ4njMKTQCM4ZFUPAieyLx4f52HuDopp3e5JyIMfW+KFcNIpKwCsak
oSoKtIUOsUJK7qBVZxcrIyeQV2qcYOeZhtS5wBqIwOAhFwlCET7Ze58QHmS48slj
S9K0JAcps2xdnGu0fkzhSQxY8GPQNFTlr6rYld5+ID/hHeS76gq0YG3q6RLWRkHf
4eTkRjivAlExrFzKcljC4axKQlnOvVAzz+Gm32U0xPBF4ByePVxCJUHw1TsyTmel
RxNEp7yHoXcwn+fXna+t5JWh1gxUZty3
-----END CERTIFICATE-----
  '';

  environment.etc."NetworkManager/system-connections/RDU2.ovpn" = {
    mode = "0400";
    text = ''
      [connection]
      id=Raleigh (RDU2)
      uuid=f281b867-85e1-4979-8adf-ad9fac216a7c
      type=vpn
      permissions=

      [vpn]
      ca=/etc/pki/tls/certs/ca-bundle.crt
      cipher=AES-256-CBC
      connection-type=password
      password-flags=2
      port=443
      remote=ovpn-rdu2.redhat.com
      reneg-seconds=0
      tunnel-mtu=1360
      username=ihrachys
      verify-x509-name=name:ovpn.redhat.com
      service-type=org.freedesktop.NetworkManager.openvpn

      [ipv4]
      dns-search=
      method=auto
      never-default=true

      [ipv6]
      addr-gen-mode=stable-privacy
      dns-search=
      method=auto
    '';
  };

  security.pki.certificates = [
    ''
2015-RH-IT-Root-CA.pem
-----BEGIN CERTIFICATE-----
MIIENDCCAxygAwIBAgIJANunI0D662cnMA0GCSqGSIb3DQEBCwUAMIGlMQswCQYD
VQQGEwJVUzEXMBUGA1UECAwOTm9ydGggQ2Fyb2xpbmExEDAOBgNVBAcMB1JhbGVp
Z2gxFjAUBgNVBAoMDVJlZCBIYXQsIEluYy4xEzARBgNVBAsMClJlZCBIYXQgSVQx
GzAZBgNVBAMMElJlZCBIYXQgSVQgUm9vdCBDQTEhMB8GCSqGSIb3DQEJARYSaW5m
b3NlY0ByZWRoYXQuY29tMCAXDTE1MDcwNjE3MzgxMVoYDzIwNTUwNjI2MTczODEx
WjCBpTELMAkGA1UEBhMCVVMxFzAVBgNVBAgMDk5vcnRoIENhcm9saW5hMRAwDgYD
VQQHDAdSYWxlaWdoMRYwFAYDVQQKDA1SZWQgSGF0LCBJbmMuMRMwEQYDVQQLDApS
ZWQgSGF0IElUMRswGQYDVQQDDBJSZWQgSGF0IElUIFJvb3QgQ0ExITAfBgkqhkiG
9w0BCQEWEmluZm9zZWNAcmVkaGF0LmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEP
ADCCAQoCggEBALQt9OJQh6GC5LT1g80qNh0u50BQ4sZ/yZ8aETxt+5lnPVX6MHKz
bfwI6nO1aMG6j9bSw+6UUyPBHP796+FT/pTS+K0wsDV7c9XvHoxJBJJU38cdLkI2
c/i7lDqTfTcfLL2nyUBd2fQDk1B0fxrskhGIIZ3ifP1Ps4ltTkv8hRSob3VtNqSo
GxkKfvD2PKjTPxDPWYyruy9irLZioMffi3i/gCut0ZWtAyO3MVH5qWF/enKwgPES
X9po+TdCvRB/RUObBaM761EcrLSM1GqHNueSfqnho3AjLQ6dBnPWlo638Zm1VebK
BELyhkLWMSFkKwDmne0jQ02Y4g075vCKvCsCAwEAAaNjMGEwHQYDVR0OBBYEFH7R
4yC+UehIIPeuL8Zqw3PzbgcZMB8GA1UdIwQYMBaAFH7R4yC+UehIIPeuL8Zqw3Pz
bgcZMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEB
CwUAA4IBAQBDNvD2Vm9sA5A9AlOJR8+en5Xz9hXcxJB5phxcZQ8jFoG04Vshvd0e
LEnUrMcfFgIZ4njMKTQCM4ZFUPAieyLx4f52HuDopp3e5JyIMfW+KFcNIpKwCsak
oSoKtIUOsUJK7qBVZxcrIyeQV2qcYOeZhtS5wBqIwOAhFwlCET7Ze58QHmS48slj
S9K0JAcps2xdnGu0fkzhSQxY8GPQNFTlr6rYld5+ID/hHeS76gq0YG3q6RLWRkHf
4eTkRjivAlExrFzKcljC4axKQlnOvVAzz+Gm32U0xPBF4ByePVxCJUHw1TsyTmel
RxNEp7yHoXcwn+fXna+t5JWh1gxUZty3
-----END CERTIFICATE-----
    ''
    ''
oracle_ebs.crt
-----BEGIN CERTIFICATE-----
MIICxDCCAoKgAwIBAgIETpxe9zALBgcqhkjOOAQDBQAwRDELMAkGA1UEBhMCVVMxDjAMBgNVBAoT
BWFwcDAxMQ0wCwYDVQQLEwRhcHBzMRYwFAYDVQQDDA1lYnNnb2xkX2FwcDAxMCAXDTExMTAxNzE2
NTkzNVoYDzIwNTExMDA3MTY1OTM1WjBEMQswCQYDVQQGEwJVUzEOMAwGA1UEChMFYXBwMDExDTAL
BgNVBAsTBGFwcHMxFjAUBgNVBAMMDWVic2dvbGRfYXBwMDEwggG4MIIBLAYHKoZIzjgEATCCAR8C
gYEA/X9TgR11EilS30qcLuzk5/YRt1I870QAwx4/gLZRJmlFXUAiUftZPY1Y+r/F9bow9subVWzX
gTuAHTRv8mZgt2uZUKWkn5/oBHsQIsJPu6nX/rfGG/g7V+fGqKYVDwT7g/bTxR7DAjVUE1oWkTL2
dfOuK2HXKu/yIgMZndFIAccCFQCXYFCPFSMLzLKSuYKi64QL8Fgc9QKBgQD34aCF1ps93su8q1w2
uFe5eZSvu/o66oL5V0wLPQeCZ1FZV4661FlP5nEHEIGAtEkWcSPoTCgWE7fPCTKMyKbhPBZ6i1R8
jSjgo64eK7OmdZFuo38L+iE1YvH7YnoBJDvMpPG+qFGQiaiD3+Fa5Z8GkotmXoB7VSVkAUw7/s9J
KgOBhQACgYEAz6MmM2ZIqg2KIta1LGq8rUJloM4h+j0rYyAe03Yc3prYrOtw1+e5ZhBgaKB3sgax
YXW4qS6nCi3Q0N6/mkPyy1Osr0ZbWuas/lJEsObVwHtGze9xY3dUKPA3vLcveo2xQgQKCuR474fq
QlHQRts5ij3sLKgDiKh1K7gT4CqWcKkwCwYHKoZIzjgEAwUAAy8AMCwCFHVj6UN0qT4hu2wHkiBs
mynaWQG3AhQ9JNpqp97p5+wSV3Bb/KeuraqI/g==
-----END CERTIFICATE-----
    ''
    ''
newca.crt
-----BEGIN CERTIFICATE-----
MIIDsDCCAxmgAwIBAgIBATANBgkqhkiG9w0BAQUFADCBnTELMAkGA1UEBhMCVVMx
FzAVBgNVBAgTDk5vcnRoIENhcm9saW5hMRAwDgYDVQQHEwdSYWxlaWdoMRYwFAYD
VQQKEw1SZWQgSGF0LCBJbmMuMQswCQYDVQQLEwJJUzEWMBQGA1UEAxMNUmVkIEhh
dCBJUyBDQTEmMCQGCSqGSIb3DQEJARYXc3lzYWRtaW4tcmR1QHJlZGhhdC5jb20w
HhcNMDkwOTE2MTg0NTI1WhcNMTkwOTE0MTg0NTI1WjCBnTELMAkGA1UEBhMCVVMx
FzAVBgNVBAgTDk5vcnRoIENhcm9saW5hMRAwDgYDVQQHEwdSYWxlaWdoMRYwFAYD
VQQKEw1SZWQgSGF0LCBJbmMuMQswCQYDVQQLEwJJUzEWMBQGA1UEAxMNUmVkIEhh
dCBJUyBDQTEmMCQGCSqGSIb3DQEJARYXc3lzYWRtaW4tcmR1QHJlZGhhdC5jb20w
gZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBAN/HDWGiL8BarUWDIjNC6uxCXqYN
QkwcmhILX+cl+YuDDArFL1pYVrith228gF3dSUU5X7kIOmPkkjNheRkbnas61X+n
i3+KWvbX3q+h5VMxKX2cA1U+R3jLuXqYjF+N2gkPyPvxeoDuEncKAItw+mK/r+4L
WBb5nFzek7hP3017AgMBAAGjgf0wgfowHQYDVR0OBBYEFA2sGXDtBKdeeKv+i6g0
6yEmwVY1MIHKBgNVHSMEgcIwgb+AFA2sGXDtBKdeeKv+i6g06yEmwVY1oYGjpIGg
MIGdMQswCQYDVQQGEwJVUzEXMBUGA1UECBMOTm9ydGggQ2Fyb2xpbmExEDAOBgNV
BAcTB1JhbGVpZ2gxFjAUBgNVBAoTDVJlZCBIYXQsIEluYy4xCzAJBgNVBAsTAklT
MRYwFAYDVQQDEw1SZWQgSGF0IElTIENBMSYwJAYJKoZIhvcNAQkBFhdzeXNhZG1p
bi1yZHVAcmVkaGF0LmNvbYIBATAMBgNVHRMEBTADAQH/MA0GCSqGSIb3DQEBBQUA
A4GBAFBgO5y3JcPXH/goumNBW7rr8m9EFZmQyK5gT1Ljv5qaCSZwxkAomhriv04p
mb1y8yjrK5OY3WwgaRaAWRHp4/hn2HWaRvx3S+gwLM7p8V1pWnbSFJOXF3kbuC41
voMIMqAFfHKidKN/yrjJg/1ahIjSt11lMUvRJ4TNT+pk5VnB
-----END CERTIFICATE-----
    ''
  ];

  # Select i18n properties.
  i18n = {
    consoleFont = "Lat2-Terminus16";
    consoleKeyMap = "us";
    defaultLocale = "en_US.UTF-8";
  };

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # List packages installed in system profile.
  environment.systemPackages = with pkgs; [
    # hw
    dmidecode pciutils
    # dev
    git gitAndTools.tig gitAndTools.git-hub strace ltrace gcc gnumake patchelf
    gdb
    # network
    telnet lsof openssl tcpdump wireshark dnsutils
    # misc
    emacs vim pass gnupg file tmux pstree ranger bc gnumake go gcc wget zip
    poppler_utils pastebinit fortune
    # virt
    vagrant skopeo
    # gui
    firefox slack libreoffice zathura evince zoom-us scrot xscreensaver
    # terminal
    rxvt_unicode-with-plugins urxvt_perl urxvt_font_size autocutsel
    # media
    mpc_cli ncmpcpp spotify mplayer vlc
    # twitter
    turses rainbowstream oysttyer
    # learn how to manage virtual environments in nixos properly
    (python3.withPackages(ps: with ps; [
        pip setuptools tox virtualenvwrapper arrow matplotlib
    ]))
  ];

  # Install flash plugin for firefox.
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.enableParallelBuilding = true;
  nixpkgs.config.firefox.enableAdobeFlash = true;
  nixpkgs.config.firefox.gssSupport = true;

  # User session adjustments.
  programs.gnupg.agent = { enable = true; };
  #programs.gnupg.agent = { enable = true; enableSSHSupport = true; };
  programs.bash.enableCompletion = true;
  programs.vim.defaultEditor = true;

  # List services that you want to enable:

  # Don't rate limit journal log messages.
  services.journald.rateLimitInterval = "0";

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  programs.ssh.startAgent = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable flatpak service.
  services.flatpak.enable = true;

  # Virtualization.
  virtualisation = {
    docker.enable = true;
    libvirtd.enable = true;
  };
  boot.extraModprobeConfig = "options kvm_intel nested=1";

  sound = {
    # Enable sound.
    enable = true;
    # Use second card (pcm) by default.
    extraConfig = ''
      defaults.pcm.card 1
      defaults.ctl.card 1
    '';
  };

  # Enable media keys.
  sound.mediaKeys = {
    enable = true;
    volumeStep = "3%";
  };
  services.actkbd = {
    enable = true;
  };

  # Enable Mopidy for Spotify.
  services.mopidy = {
    enable = true;
    extensionPackages = [ pkgs.mopidy-iris pkgs.mopidy-mopify pkgs.mopidy-spotify pkgs.mopidy-spotify-tunigo ];
    extraConfigFiles = [ "/etc/nixos/mopidy.conf" ];
  };

  # X server.
  services.xserver = {
    # Enable the X11 windowing system.
    enable = true;
    layout = "us,by,ru";
    xkbOptions = "grp:caps_toggle";

    # Enable touchpad support.
    # services.xserver.libinput.enable = true;

    # Enable Awesome window manager.
    windowManager.awesome.enable = true;

    displayManager = {
      gdm.enable = true;
      #gdm.wayland = false;
      sessionCommands =  ''
         xrdb "${pkgs.writeText  "xrdb.conf" ''
           URxvt.font:                 xft:Dejavu Sans Mono for Powerline:size=11
           XTerm*faceName:             xft:Dejavu Sans Mono for Powerline:size=11
           XTerm*utf8:                 2
           URxvt.letterSpace:          0
           URxvt.background:           #121214
           URxvt.foreground:           #FFFFFF
           XTerm*background:           #121212
           XTerm*foreground:           #FFFFFF
           ! black
           URxvt.color0  :             #2E3436
           URxvt.color8  :             #555753
           XTerm*color0  :             #2E3436
           XTerm*color8  :             #555753
           ! red
           URxvt.color1  :             #CC0000
           URxvt.color9  :             #EF2929
           XTerm*color1  :             #CC0000
           XTerm*color9  :             #EF2929
           ! green
           URxvt.color2  :             #4E9A06
           URxvt.color10 :             #8AE234
           XTerm*color2  :             #4E9A06
           XTerm*color10 :             #8AE234
           ! yellow
           URxvt.color3  :             #C4A000
           URxvt.color11 :             #FCE94F
           XTerm*color3  :             #C4A000
           XTerm*color11 :             #FCE94F
           ! blue
           URxvt.color4  :             #3465A4
           URxvt.color12 :             #729FCF
           XTerm*color4  :             #3465A4
           XTerm*color12 :             #729FCF
           ! magenta
           URxvt.color5  :             #75507B
           URxvt.color13 :             #AD7FA8
           XTerm*color5  :             #75507B
           XTerm*color13 :             #AD7FA8
           ! cyan
           URxvt.color6  :             #06989A
           URxvt.color14 :             #34E2E2
           XTerm*color6  :             #06989A
           XTerm*color14 :             #34E2E2
           ! white
           URxvt.color7  :             #D3D7CF
           URxvt.color15 :             #EEEEEC
           XTerm*color7  :             #D3D7CF
           XTerm*color15 :             #EEEEEC
           URxvt*saveLines:            32767
           XTerm*saveLines:            32767
           URxvt.colorUL:              #AED210
           URxvt.perl-ext-common:      default,url-select,keyboard-select,font-size
           URxvt.keysym.M-u:           perl:url-select:select_next
           URxvt.keysym.M-Escape:      perl:keyboard-select:activate
           URxvt.keysym.M-s:           perl:keyboard-select:search
           URxvt.keysym.C-Up:          font-size:increase
           URxvt.keysym.C-Down:        font-size:decrease
           URxvt.keysym.C-S-Up:        font-size:incglobal
           URxvt.keysym.C-S-Down:      font-size:decglobal
           URxvt.keysym.C-equal:       font-size:reset
           URxvt.keysym.C-slash:       font-size:show
           URxvt.url-select.launcher:  /usr/bin/env xdg-open
           URxvt.url-select.underline: true
           Xft*dpi:                    96
           Xft*antialias:              true
           Xft*hinting:                full
           URxvt.scrollBar:            false
           URxvt*scrollTtyKeypress:    true
           URxvt*scrollTtyOutput:      false
           URxvt*scrollWithBuffer:     false
           URxvt*scrollstyle:          plain
           URxvt*secondaryScroll:      true
           Xft.autohint: 0
           Xft.lcdfilter:  lcddefault
           Xft.hintstyle:  hintfull
           Xft.hinting: 1
           Xft.antialias: 1
         ''}"
         ${pkgs.autocutsel}/bin/autocutsel -fork
         ${pkgs.autocutsel}/bin/autocutsel -selection PRIMARY -fork
         ${pkgs.xscreensaver}/bin/xscreensaver -no-splash &
      '';
    };
  };

  # Install fonts.
  fonts = {
    enableFontDir = true;
    enableGhostscriptFonts = true;
    fonts = with pkgs; [
      anonymousPro
      corefonts
      dejavu_fonts
      font-droid
      freefont_ttf
      google-fonts
      inconsolata
      liberation_ttf
      powerline-fonts
      source-code-pro
      terminus_font
      ttf_bitstream_vera
      ubuntu_font_family
    ];
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.ihar = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [
      "wheel" "disk" "audio" "video" "networkmanager" "systemd-journal"
      "docker" "libvirtd"
    ];
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "18.09"; # Did you read the comment?
}
