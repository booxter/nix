{ pkgs, kernel }:
pkgs.stdenv.mkDerivation {
  pname = "cake-idle-decay-module";
  inherit (kernel) version;

  src = kernel.src;
  unpackPhase = ''
    tar -xf "$src" --strip-components=3 --wildcards '*/net/sched/sch_cake.c'
  '';
  patches = [ ./cake-idle-decay.patch ];

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
  installPhase = ''
    mkdir -p "$out"
    cp sch_cake.ko "$out/"
  '';
}
