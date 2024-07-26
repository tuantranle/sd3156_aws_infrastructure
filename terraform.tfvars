subnet_prefix = [
  {
    cidr_block = "10.0.1.0/24",
    name       = "Subnet-1"
  },
  {
    cidr_block = "10.0.2.0/24",
    name       = "Subnet-2"
  },
  {
    cidr_block = "10.0.3.0/24",
    name       = "Subnet-3"
  }
]

cluster_addons = {
  coredns = {
    resolve_conflicts_on_update = "OVERWRITE"
  }
  kube-proxy = {}
  vpc-cni = {
    resolve_conflicts_on_update = "OVERWRITE"
  }
}


access_key = "AKIAXPOBRGRWYWQDZT5H"
secret_key = "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"