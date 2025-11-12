---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: ${ami_family}
  amiSelectorTerms:
    - alias: ${ami_family == "AL2023" ? "al2023@latest" : "al2@latest"}
  instanceProfile: "$${NODE_INSTANCE_PROFILE}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "$${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "$${CLUSTER_NAME}"
  # 🔽 NEW: give Karpenter nodes a friendly Name tag, etc.
  tags:
    Name: "${name_tag}"
    Environment: "${env_name}"
    Project: "EKS-Karpenter"
    Managed: "Terraform"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ${jsonencode(capacity_types)}
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ${jsonencode(instance_families)}
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ${jsonencode(instance_sizes)}
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      taints:
        - key: workload
          value: general
          effect: NoSchedule
  limits:
    cpu: "${cpu_limit}"
    memory: "${memory_limit}"
  disruption:
    consolidationPolicy: ${jsonencode(consolidation_policy)}
    consolidateAfter: "${consolidate_after}"
