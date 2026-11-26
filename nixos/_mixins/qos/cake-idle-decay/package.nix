{ pkgs, kernel }:
pkgs.stdenv.mkDerivation {
  pname = "cake-idle-decay-module";
  inherit (kernel) version;

  src = kernel.src;
  unpackPhase = ''
    tar -xf "$src" --strip-components=3 --wildcards '*/net/sched/sch_cake.c'
  '';
  patches = [ ../../../../patches/linux-cake-decay-blue-penalty-while-idle.patch ];

  nativeBuildInputs = kernel.moduleBuildDependencies;
  hardeningDisable = [ "pic" ];
  preBuild = ''
    echo 'obj-m += sch_cake.o' > Makefile
  '';
  makeFlags = kernel.commonMakeFlags ++ [
    "KBUILD_OUTPUT=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "modules"
  ];
  # NixOS merges this depmod configuration into the module tree before indexing
  # it, so both explicit modprobe calls and qdisc autoloading select our copy.
  installPhase = ''
    install -D sch_cake.ko "$out/lib/modules/${kernel.modDirVersion}/updates/sch_cake.ko"
    mkdir -p "$out/etc/depmod.d"
    echo 'override sch_cake * updates' > "$out/etc/depmod.d/cake-idle-decay.conf"
  '';
}
