# configuration.nix for ec2 instances with linux 5.5 / ena 2.2.3 and XDP
# enabled.

{ config, lib, pkgs, ... }:
{
  imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];
  ec2.hvm = true;

  boot.kernelPackages = let
    linux_pkg = { fetchurl, buildLinux, ... } @ args:

      buildLinux (args // rec {
        version = "5.5.0";
        modDirVersion = version;

        src = fetchurl {
          url = "https://github.com/torvalds/linux/archive/v5.5.tar.gz";
          sha256 = "87c2ecdd31fcf479304e95977c3600b3381df32c58a260c72921a6bb7ea62950";
        };
        kernelPatches = [];

        extraConfig = ''
          XDP_SOCKETS y
        '';

        extraMeta.branch = "5.5";
      } // (args.argsOverride or {}));
    linux = pkgs.callPackage linux_pkg{};
  in 
    pkgs.recurseIntoAttrs (pkgs.linuxPackagesFor linux);

  environment.systemPackages = with pkgs; [
    gcc glibc binutils git gnumake wget nmap screen tmux pciutils tcpdump curl
    strace htop file cpulimit numactl psmisc linuxPackages.perf nox nixops lsof
    iperf3 emacs ethtool
    # manpages
    manpages
    posix_man_pages
  ];

}
