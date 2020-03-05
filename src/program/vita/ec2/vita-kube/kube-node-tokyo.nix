{ config, lib, pkgs, ... }:
{
  imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];
  ec2.hvm = true;

  environment.systemPackages = with pkgs; [
    gcc glibc binutils git gnumake wget nmap screen tmux pciutils tcpdump curl
    strace htop file cpulimit numactl psmisc linuxPackages.perf nox nixops lsof
    iperf3 emacs ethtool traceroute
    # manpages
    manpages
    posix_man_pages
  ];

  networking.hostName = "kube-node-tokyo";
  networking.extraHosts = ''
    127.0.0.1 kube-node-tokyo
    172.31.29.204 kube-master
  '';
  # ip route add 172.31.0.0/16 via 172.32.9.53 dev eth0 src 172.32.14.154 mtu 1440
  networking.firewall.enable = false;

  services.kubernetes = {
    roles = ["node"];
    masterAddress = "kube-master";
    apiserverAddress = "https://kube-master:6443";
  };

  # https://nixos.org/nixos/manual/index.html#sec-kubernetes
  # cat /var/lib/kubernetes/secrets/apitoken.secret | nixos-kubernetes-node-join

}
