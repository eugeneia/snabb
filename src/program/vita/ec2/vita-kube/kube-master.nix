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
    # k8s
    kubectl
  ];

  networking.hostName = "kube-master";
  networking.extraHosts = ''
    127.0.0.1 kube-master
    172.32.14.154 kube-node-tokyo
  '';
  # ip route add 172.32.0.0/16 via 172.31.28.238 src 172.31.29.204 dev eth0 mtu 1440
  networking.firewall.enable = false;

  services.kubernetes = {
    roles = ["master"];
    masterAddress = "kube-master";
    apiserverAddress = "https://kube-master:6443";
  };

  # https://nixos.org/nixos/manual/index.html#sec-kubernetes
  # cat /var/lib/kubernetes/secrets/apitoken.secret | nixos-kubernetes-node-join
  # export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig
  # kubectl get nodes
  # kubectl --namespace kube-system get pods

}
