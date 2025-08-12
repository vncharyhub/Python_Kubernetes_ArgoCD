resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deployer" {
  key_name   = var.key_name
  public_key = tls_private_key.ssh_key.public_key_openssh
}

resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "k8s-learning-vpc"
  }
}

resource "aws_subnet" "subnet" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "k8s-learning-subnet"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# For learning: Security group allows all inbound (0.0.0.0/0) - NOT for production
resource "aws_security_group" "all_open" {
  name        = "k8s-all-open-sg"
  description = "Allow all inbound outbound (learning only)"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  bootstrap = <<-EOT
    #!/bin/bash
    set -ex

    # Disable swap
    swapoff -a
    sed -i.bak -r 's/(.+ swap .+)/#\\1/' /etc/fstab || true

    # Kernel modules
    cat > /etc/modules-load.d/k8s.conf <<'MODULES'
    overlay
    br_netfilter
    MODULES

    modprobe overlay
    modprobe br_netfilter

    # sysctl params
    cat > /etc/sysctl.d/99-k8s.conf <<'SYSCTL'
    net.bridge.bridge-nf-call-ip6tables = 1
    net.bridge.bridge-nf-call-iptables = 1
    net.ipv4.ip_forward = 1
    SYSCTL

    sysctl --system

    # Install containerd
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y containerd.io

    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    systemctl restart containerd
    systemctl enable containerd

    # Install kubeadm, kubelet, kubectl
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list

    apt-get update -y
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

    # allow passwordless sudo for ubuntu user (default ubuntu has passwordless)
    # ensure ubuntu user can use kubectl later (we'll adjust kubeconfig after init)
    touch /home/ubuntu/.k8s-ready
    chown ubuntu:ubuntu /home/ubuntu/.k8s-ready
  EOT
}

# Master instance
resource "aws_instance" "master" {
  ami                    = var.ami
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.subnet.id
  vpc_security_group_ids = [aws_security_group.all_open.id]
  user_data              = local.bootstrap
  tags = {
    Name = "k8s-master"
  }
}

# Worker instance
resource "aws_instance" "worker" {
  ami                    = var.ami
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.subnet.id
  vpc_security_group_ids = [aws_security_group.all_open.id]
  user_data              = local.bootstrap
  tags = {
    Name = "k8s-worker"
  }
}

# Save the private key to a local file via local-exec (on the machine running terraform)
resource "local_file" "private_key_pem" {
  content  = tls_private_key.ssh_key.private_key_pem
  filename = "${path.module}/k8s-learning-key.pem"
  file_permission = "0600"
}

# Optional: small delay to let cloud-init finish
resource "null_resource" "wait_for_boot" {
  provisioner "local-exec" {
    command = "echo 'Waiting 30s for instances to finish initialization...' && sleep 30"
  }
  depends_on = [aws_instance.master, aws_instance.worker]
}
