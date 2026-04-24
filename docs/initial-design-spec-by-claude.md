# OpenShift Dedicated (OSD) BGP Integration on Google Cloud
## Implementation Guide

---

## Executive Summary

This document provides the exact sequence of steps to implement BGP-based direct routing for OpenShift Dedicated on Google Cloud, enabling IP address preservation during migrations and direct pod-to-external connectivity without NAT. This solution mirrors the ROSA BGP implementation on AWS but leverages Google Cloud Router instead of AWS VPC Route Server.

---

## Network Architecture

### Network Segments

| Network Domain | CIDR Range | Purpose |
|----------------|------------|---------|
| OSD VPC Network | 10.0.0.0/16 | Hosts OpenShift cluster and worker nodes |
| Pod/VM Network (UDN) | 10.100.0.0/16 | User-Defined Network for pods and VMs |
| External VPC | 192.168.0.0/16 | Connected via VPC Peering or Cloud Interconnect |

### Key Components

- **Google Cloud Router**: BGP speaker that peers with OSD worker nodes
- **FRRouting (FRR)**: BGP daemon running on designated OSD router nodes
- **OVN-Kubernetes**: OpenShift networking with route advertisement enabled
- **User-Defined Network (UDN)**: Custom network for VM/Pod IP ranges

---

## Prerequisites

### Required Access & Tools

1. **Google Cloud CLI (gcloud)** - authenticated with appropriate permissions
2. **OpenShift CLI (oc)** - version 4.14 or higher
3. **Terraform** (optional) - for infrastructure automation
4. **Google Cloud Project** with:
   - Compute Engine API enabled
   - Service Networking API enabled
   - Appropriate IAM permissions (Compute Admin, Network Admin)

### Required Permissions

- `compute.instances.*`
- `compute.networks.*`
- `compute.routers.*`
- `compute.routes.*`
- `container.clusters.*` (for OSD management)

### Network Planning

Define your network ranges before beginning:
- OSD VPC CIDR
- Pod network CIDR (for UDN)
- External network CIDRs
- BGP ASN assignments (e.g., OSD: 65003, Cloud Router: 65002)

---

## Implementation Steps

### Phase 1: Google Cloud Infrastructure Setup

#### Step 1.1: Create VPC Networks

```bash
# Create primary VPC for OSD cluster
gcloud compute networks create osd-vpc \
  --subnet-mode=custom \
  --bgp-routing-mode=regional \
  --project=YOUR_PROJECT_ID

# Create subnets across multiple zones for HA
gcloud compute networks subnets create osd-subnet-zone-a \
  --network=osd-vpc \
  --region=us-central1 \
  --range=10.0.1.0/24 \
  --project=YOUR_PROJECT_ID

gcloud compute networks subnets create osd-subnet-zone-b \
  --network=osd-vpc \
  --region=us-central1 \
  --range=10.0.2.0/24 \
  --secondary-range pod-range=10.100.0.0/16 \
  --project=YOUR_PROJECT_ID

gcloud compute networks subnets create osd-subnet-zone-c \
  --network=osd-vpc \
  --region=us-central1 \
  --range=10.0.3.0/24 \
  --project=YOUR_PROJECT_ID

# Create external VPC (for testing connectivity)
gcloud compute networks create external-vpc \
  --subnet-mode=custom \
  --bgp-routing-mode=regional \
  --project=YOUR_PROJECT_ID

gcloud compute networks subnets create external-subnet \
  --network=external-vpc \
  --region=us-central1 \
  --range=192.168.0.0/24 \
  --project=YOUR_PROJECT_ID
```

#### Step 1.2: Set Up VPC Peering (or Cloud Interconnect)

```bash
# Create VPC peering between OSD VPC and External VPC
gcloud compute networks peerings create osd-to-external \
  --network=osd-vpc \
  --peer-network=external-vpc \
  --import-custom-routes \
  --export-custom-routes \
  --project=YOUR_PROJECT_ID

gcloud compute networks peerings create external-to-osd \
  --network=external-vpc \
  --peer-network=osd-vpc \
  --import-custom-routes \
  --export-custom-routes \
  --project=YOUR_PROJECT_ID
```

#### Step 1.3: Create Cloud Router

```bash
# Create Cloud Router in the OSD VPC
gcloud compute routers create osd-cloud-router \
  --network=osd-vpc \
  --region=us-central1 \
  --asn=65002 \
  --project=YOUR_PROJECT_ID
```

#### Step 1.4: Reserve Internal IP Addresses for BGP Peering

**Important**: You need to create internal IP addresses for each router node to peer with Cloud Router.

```bash
# Reserve internal IPs for BGP router nodes (one per zone for HA)
gcloud compute addresses create bgp-router-ip-zone-a \
  --region=us-central1 \
  --subnet=osd-subnet-zone-a \
  --addresses=10.0.1.10 \
  --project=YOUR_PROJECT_ID

gcloud compute addresses create bgp-router-ip-zone-b \
  --region=us-central1 \
  --subnet=osd-subnet-zone-b \
  --addresses=10.0.2.10 \
  --project=YOUR_PROJECT_ID

gcloud compute addresses create bgp-router-ip-zone-c \
  --region=us-central1 \
  --subnet=osd-subnet-zone-c \
  --addresses=10.0.3.10 \
  --project=YOUR_PROJECT_ID
```

---

### Phase 2: OpenShift Dedicated Cluster Deployment

#### Step 2.1: Deploy OSD Cluster

**Option A: Using OpenShift Cluster Manager UI**
1. Navigate to https://console.redhat.com/openshift
2. Create new OpenShift Dedicated cluster on Google Cloud
3. Configure:
   - Region: us-central1
   - Network: Use existing VPC (osd-vpc)
   - Subnets: Select the created subnets
   - Worker node machine type: n2-standard-8 or larger
   - Multi-AZ deployment: Enabled

**Option B: Using OCM CLI**

```bash
ocm create cluster \
  --name=osd-bgp-cluster \
  --provider=gcp \
  --region=us-central1 \
  --version=4.16 \
  --compute-machine-type=n2-standard-8 \
  --compute-nodes=3 \
  --multi-az \
  --network-type=OVNKubernetes \
  --vpc-name=osd-vpc \
  --subnet-ids=osd-subnet-zone-a,osd-subnet-zone-b,osd-subnet-zone-c
```

#### Step 2.2: Create Dedicated Router Node Pools

Create machine pools with nodes dedicated to BGP routing (one per zone):

```bash
# Create router node pool for zone A
ocm create machinepool \
  --cluster=osd-bgp-cluster \
  --instance-type=n2-standard-4 \
  --replicas=1 \
  --labels="bgp_router=true,zone=a" \
  --name=router-pool-a \
  --availability-zone=us-central1-a

# Create router node pool for zone B
ocm create machinepool \
  --cluster=osd-bgp-cluster \
  --instance-type=n2-standard-4 \
  --replicas=1 \
  --labels="bgp_router=true,zone=b" \
  --name=router-pool-b \
  --availability-zone=us-central1-b

# Create router node pool for zone C
ocm create machinepool \
  --cluster=osd-bgp-cluster \
  --instance-type=n2-standard-4 \
  --replicas=1 \
  --labels="bgp_router=true,zone=c" \
  --name=router-pool-c \
  --availability-zone=us-central1-c
```

#### Step 2.3: Wait for Cluster Readiness

```bash
# Monitor cluster installation
ocm describe cluster osd-bgp-cluster

# Wait for cluster to be ready (typically 30-45 minutes)
watch -n 30 'ocm describe cluster osd-bgp-cluster | grep State'
```

#### Step 2.4: Authenticate to Cluster

```bash
# Get cluster credentials
ocm get cluster osd-bgp-cluster --json | jq -r .console.url

# Create admin user (if needed)
ocm create idp \
  --cluster=osd-bgp-cluster \
  --type=htpasswd \
  --name=admin \
  --username=admin \
  --password=YOUR_SECURE_PASSWORD

# Login via oc CLI
oc login <API_URL> -u admin -p YOUR_SECURE_PASSWORD
```

---

### Phase 3: Configure OpenShift Networking for BGP

#### Step 3.1: Enable FRR and Route Advertisements

```bash
# Patch the network operator to enable FRR routing capabilities
oc patch Network.operator.openshift.io cluster --type=merge \
  -p='{"spec":{
    "additionalRoutingCapabilities": {"providers": ["FRR"]},
    "defaultNetwork":{
      "ovnKubernetesConfig":{
        "routeAdvertisements":"Enabled"
      }
    }
  }}'

# Verify the patch was applied
oc get Network.operator.openshift.io cluster -o yaml | grep -A 5 additionalRoutingCapabilities
```

#### Step 3.2: Wait for FRR Namespace Creation

```bash
# Wait for the openshift-frr-k8s namespace to be created (may take 1-2 minutes)
until oc get namespace openshift-frr-k8s 2>/dev/null; do
  echo "Waiting for openshift-frr-k8s namespace..."
  sleep 10
done

echo "FRR namespace created successfully"
```

#### Step 3.3: Configure BGP Peering with Cloud Router

**Important Note**: You need to know the Cloud Router's BGP peer IPs. In Google Cloud, you'll configure BGP sessions on the Cloud Router side first, then configure FRR to match.

##### Step 3.3a: Configure Cloud Router BGP Peers

First, identify the internal IPs of your router nodes:

```bash
# Get router node IPs
oc get nodes -l bgp_router=true -o wide
```

For each router node, create a BGP peer on Cloud Router:

```bash
# Add BGP peer for router node in zone A (example IP: 10.0.1.10)
gcloud compute routers add-bgp-peer osd-cloud-router \
  --peer-name=osd-router-zone-a \
  --peer-asn=65003 \
  --interface=interface-zone-a \
  --peer-ip-address=10.0.1.10 \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Add BGP peer for router node in zone B (example IP: 10.0.2.10)
gcloud compute routers add-bgp-peer osd-cloud-router \
  --peer-name=osd-router-zone-b \
  --peer-asn=65003 \
  --interface=interface-zone-b \
  --peer-ip-address=10.0.2.10 \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Add BGP peer for router node in zone C (example IP: 10.0.3.10)
gcloud compute routers add-bgp-peer osd-cloud-router \
  --peer-name=osd-router-zone-c \
  --peer-asn=65003 \
  --interface=interface-zone-c \
  --peer-ip-address=10.0.3.10 \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID
```

**Note**: You may need to create router interfaces first if they don't exist:

```bash
# Create router interface for each zone
gcloud compute routers add-interface osd-cloud-router \
  --interface-name=interface-zone-a \
  --ip-address=10.0.1.1 \
  --mask-length=24 \
  --vpn-tunnel=tunnel-zone-a \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID
```

For direct BGP peering without VPN/Interconnect, you can use the router's link-local addresses.

##### Step 3.3b: Create FRRConfiguration

Get the Cloud Router's BGP peer IPs:

```bash
# Get Cloud Router details
gcloud compute routers describe osd-cloud-router \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID
```

Create the FRR configuration:

```bash
cat <<EOF | oc apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: osd-bgp-config
  namespace: openshift-frr-k8s
spec:
  bgp:
    routers:
    - asn: 65003
      neighbors:
      # Neighbor for zone A - Cloud Router interface IP
      - address: 10.0.1.1
        asn: 65002
        port: 179
        ebgpMultihop: false
        toAdvertise:
          allowed:
            mode: all
      # Neighbor for zone B - Cloud Router interface IP
      - address: 10.0.2.1
        asn: 65002
        port: 179
        ebgpMultihop: false
        toAdvertise:
          allowed:
            mode: all
      # Neighbor for zone C - Cloud Router interface IP
      - address: 10.0.3.1
        asn: 65002
        port: 179
        ebgpMultihop: false
        toAdvertise:
          allowed:
            mode: all
  nodeSelector:
    matchLabels:
      bgp_router: "true"
EOF
```

#### Step 3.4: Verify BGP Sessions

```bash
# Check FRR pods are running
oc get pods -n openshift-frr-k8s

# Check FRR configuration
oc get frrconfiguration -n openshift-frr-k8s

# View FRR logs
oc logs -n openshift-frr-k8s -l app=frr-k8s -c frr

# Verify BGP sessions on Google Cloud side
gcloud compute routers get-status osd-cloud-router \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID
```

Expected output should show BGP sessions in "Established" state.

---

### Phase 4: Configure User-Defined Networks (UDN)

#### Step 4.1: Create ClusterUserDefinedNetwork

```bash
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: prod-udn
spec:
  namespaceSelector:
    matchLabels:
      cluster-udn: prod
  network:
    layer3:
      role: Primary
      subnets:
      - cidr: 10.100.0.0/16
        hostSubnet: 24
      mtu: 1400
      ipv4:
        enabled: true
      ipv6:
        enabled: false
EOF
```

#### Step 4.2: Create Namespace with UDN

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cudn-prod
  labels:
    cluster-udn: prod
    k8s.ovn.org/primary-user-defined-network: ""
EOF
```

#### Step 4.3: Verify UDN Creation

```bash
# Check ClusterUserDefinedNetwork
oc get clusteruserdefinednetwork

# Verify namespace labels
oc get namespace cudn-prod -o yaml

# Check OVN network configuration
oc get network-attachment-definitions -n cudn-prod
```

---

### Phase 5: Configure Route Advertisement

#### Step 5.1: Create RouteAdvertisements Resource

```bash
cat <<EOF | oc apply -f -
apiVersion: ovn.k8s.io/v1
kind: RouteAdvertisements
metadata:
  name: advertise-udn-routes
  namespace: openshift-ovn-kubernetes
spec:
  advertisements:
  - podNetwork: true
    targetVRF: prod-udn
  nodeSelector:
    matchLabels:
      bgp_router: "true"
EOF
```

#### Step 5.2: Verify Routes are Advertised

```bash
# Check routes on Cloud Router
gcloud compute routers get-status osd-cloud-router \
  --region=us-central1 \
  --format="get(result.bestRoutes)" \
  --project=YOUR_PROJECT_ID

# Should show 10.100.0.0/16 or specific pod subnets being advertised
```

```bash
# Verify routes in VPC route table
gcloud compute routes list \
  --filter="network:osd-vpc" \
  --project=YOUR_PROJECT_ID
```

You should see dynamic routes with next-hop pointing to your router node IPs.

---

### Phase 6: Deploy OpenShift Virtualization

#### Step 6.1: Install OpenShift Virtualization Operator

```bash
# Create namespace for CNV
oc create namespace openshift-cnv

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
  installPlanApproval: Automatic
EOF
```

#### Step 6.2: Create HyperConverged Instance

```bash
# Wait for operator to be ready
oc wait --for=condition=Ready subscription/hco-operatorhub \
  -n openshift-cnv \
  --timeout=300s

# Create HyperConverged instance
cat <<EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  infra:
    nodePlacement:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
  workloads:
    nodePlacement:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
EOF
```

#### Step 6.3: Verify Installation

```bash
# Check HyperConverged status
oc get hco -n openshift-cnv

# Verify all components are ready
oc get csv -n openshift-cnv
oc get pods -n openshift-cnv
```

---

### Phase 7: Test VM Deployment with Direct Routing

#### Step 7.1: Create Test VM in UDN Namespace

```bash
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm-udn
  namespace: cudn-prod
  labels:
    app: test-vm
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: test-vm-udn
    spec:
      domain:
        devices:
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
        resources:
          requests:
            memory: 1Gi
            cpu: 1
      networks:
      - name: default
        pod: {}
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/kubevirt/fedora-cloud-container-disk-demo:latest
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd: { expire: False }
            ssh_pwauth: True
EOF
```

#### Step 7.2: Get VM IP Address

```bash
# Wait for VM to be ready
oc wait --for=condition=Ready vmi/test-vm-udn -n cudn-prod --timeout=300s

# Get VM IP
VM_IP=$(oc get vmi test-vm-udn -n cudn-prod -o jsonpath='{.status.interfaces[0].ipAddress}')
echo "VM IP: $VM_IP"
```

#### Step 7.3: Test Connectivity from External VPC

```bash
# Create a test VM in external VPC
gcloud compute instances create external-test-vm \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --subnet=external-subnet \
  --network=external-vpc \
  --project=YOUR_PROJECT_ID

# SSH to external test VM
gcloud compute ssh external-test-vm \
  --zone=us-central1-a \
  --project=YOUR_PROJECT_ID

# From external VM, ping the OpenShift VM
ping $VM_IP

# Test should succeed, showing direct routing without NAT
```

#### Step 7.4: Verify No NAT Translation

```bash
# From within the OpenShift VM (console access)
oc console vmi/test-vm-udn -n cudn-prod

# Check that source IP from external network is preserved
tcpdump -i eth0 icmp

# You should see the actual external VM IP, not a translated address
```

---

### Phase 8: Validation and Troubleshooting

#### Step 8.1: Validate BGP Configuration

```bash
# Check BGP neighbor status from FRR pod
FRR_POD=$(oc get pods -n openshift-frr-k8s -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}')

oc exec -n openshift-frr-k8s $FRR_POD -c frr -- vtysh -c "show bgp summary"
oc exec -n openshift-frr-k8s $FRR_POD -c frr -- vtysh -c "show bgp neighbors"
oc exec -n openshift-frr-k8s $FRR_POD -c frr -- vtysh -c "show ip route"
```

#### Step 8.2: Validate Route Propagation

```bash
# Check Cloud Router learned routes
gcloud compute routers get-status osd-cloud-router \
  --region=us-central1 \
  --format=json \
  --project=YOUR_PROJECT_ID | jq '.result.bestRoutes'

# Check VPC routes
gcloud compute routes list \
  --filter="network:osd-vpc AND nextHopIp:(10.0.1.10 OR 10.0.2.10 OR 10.0.3.10)" \
  --project=YOUR_PROJECT_ID
```

#### Step 8.3: Test Failover

```bash
# Identify active router node
gcloud compute routes list \
  --filter="network:osd-vpc destRange:10.100.0.0/16" \
  --format="value(nextHopIp)" \
  --project=YOUR_PROJECT_ID

# Cordon the active router node
ACTIVE_NODE=$(oc get nodes -l bgp_router=true -o jsonpath='{.items[0].metadata.name}')
oc adm cordon $ACTIVE_NODE

# Wait for BGP failover (should take < 30 seconds)
sleep 30

# Verify new route is active
gcloud compute routes list \
  --filter="network:osd-vpc destRange:10.100.0.0/16" \
  --format="value(nextHopIp)" \
  --project=YOUR_PROJECT_ID

# Test connectivity still works
ping $VM_IP

# Uncordon the node
oc adm uncordon $ACTIVE_NODE
```

#### Step 8.4: Common Troubleshooting Steps

**BGP Sessions Not Establishing:**

```bash
# Check FRR configuration
oc get frrconfiguration -n openshift-frr-k8s -o yaml

# Check FRR pod logs
oc logs -n openshift-frr-k8s -l app=frr-k8s -c frr --tail=100

# Verify firewall rules allow BGP (TCP 179)
gcloud compute firewall-rules list --filter="network:osd-vpc" --project=YOUR_PROJECT_ID

# Create firewall rule if needed
gcloud compute firewall-rules create allow-bgp \
  --network=osd-vpc \
  --allow=tcp:179 \
  --source-ranges=10.0.0.0/16 \
  --project=YOUR_PROJECT_ID
```

**Routes Not Propagating:**

```bash
# Verify route advertisements are enabled
oc get Network.operator.openshift.io cluster -o yaml | grep routeAdvertisements

# Check RouteAdvertisements resource
oc get routeadvertisements -A

# Verify node labels
oc get nodes -l bgp_router=true --show-labels
```

**VM Connectivity Issues:**

```bash
# Check VM is in correct namespace
oc get vmi -n cudn-prod

# Verify UDN network attachment
oc get network-attachment-definitions -n cudn-prod

# Check OVN pod logs
oc logs -n openshift-ovn-kubernetes -l app=ovnkube-node --tail=50

# Verify security groups/firewall rules
gcloud compute firewall-rules list --filter="network:osd-vpc" --project=YOUR_PROJECT_ID
```

---

## High Availability Considerations

### Multi-Zone Router Deployment

The configuration deploys one BGP router node per availability zone:
- **Zone A**: Primary router (10.0.1.10)
- **Zone B**: Secondary router (10.0.2.10)
- **Zone C**: Tertiary router (10.0.3.10)

### Failover Mechanism

1. Cloud Router maintains BGP sessions with all three router nodes
2. Only one route is active in the VPC route table (best path selection)
3. On failure detection (BGP keepalive timeout ~90s), Cloud Router automatically selects next-best path
4. Traffic automatically reroutes to healthy router node

### Health Monitoring

```bash
# Monitor BGP session health
watch -n 5 'gcloud compute routers get-status osd-cloud-router \
  --region=us-central1 \
  --format="table(result.bgpPeerStatus[].name, result.bgpPeerStatus[].state, result.bgpPeerStatus[].uptime)" \
  --project=YOUR_PROJECT_ID'

# Monitor router node health
oc get nodes -l bgp_router=true -w
```

---

## Security Considerations

### Firewall Rules

Ensure the following firewall rules are configured:

```bash
# Allow BGP traffic (TCP 179)
gcloud compute firewall-rules create allow-bgp-internal \
  --network=osd-vpc \
  --allow=tcp:179 \
  --source-ranges=10.0.0.0/16 \
  --target-tags=osd-router-node \
  --project=YOUR_PROJECT_ID

# Allow ICMP for troubleshooting
gcloud compute firewall-rules create allow-icmp-internal \
  --network=osd-vpc \
  --allow=icmp \
  --source-ranges=10.0.0.0/16,192.168.0.0/16 \
  --project=YOUR_PROJECT_ID

# Allow pod-to-external connectivity
gcloud compute firewall-rules create allow-pod-egress \
  --network=osd-vpc \
  --allow=all \
  --source-ranges=10.100.0.0/16 \
  --direction=EGRESS \
  --project=YOUR_PROJECT_ID
```

### Network Policies

Implement Kubernetes NetworkPolicies to control pod-level access:

```bash
cat <<EOF | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-access
  namespace: cudn-prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - ipBlock:
        cidr: 192.168.0.0/16
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
EOF
```

---

## Performance Optimization

### Router Node Sizing

Recommended machine types based on workload:
- **Light (<100 VMs)**: n2-standard-4 (4 vCPU, 16 GB RAM)
- **Medium (100-500 VMs)**: n2-standard-8 (8 vCPU, 32 GB RAM)
- **Heavy (>500 VMs)**: n2-standard-16 (16 vCPU, 64 GB RAM)

### MTU Configuration

Adjust MTU for optimal performance:

```bash
# Update UDN MTU
oc patch clusteruserdefinednetwork prod-udn --type=merge \
  -p='{"spec":{"network":{"layer3":{"mtu":1460}}}}'
```

### BGP Tuning

Adjust BGP timers for faster failover:

```bash
cat <<EOF | oc apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: osd-bgp-config
  namespace: openshift-frr-k8s
spec:
  bgp:
    routers:
    - asn: 65003
      neighbors:
      - address: 10.0.1.1
        asn: 65002
        keepaliveTime: 3s
        holdTime: 9s
        toAdvertise:
          allowed:
            mode: all
  nodeSelector:
    matchLabels:
      bgp_router: "true"
EOF
```

---

## Cost Optimization

### Resource Costs

Key Google Cloud resources and estimated monthly costs:
- **Cloud Router**: $0.70 per hour = ~$504/month
- **BGP Peering**: $0.025 per peering/hour = ~$18/month per peer (x3 = $54/month)
- **OSD Router Nodes** (n2-standard-4 x3): ~$300/month
- **Data Transfer**: Variable based on traffic

### Cost-Saving Tips

1. Use preemptible instances for dev/test router nodes
2. Consolidate router nodes in single zone for non-HA dev environments
3. Use VPC Peering instead of Cloud Interconnect when possible
4. Monitor and optimize data transfer costs

---

## Migration Strategy

### Migrating from Legacy VMware Environments

#### Phase 1: Network Planning
1. Document existing IP allocations
2. Map VLAN segments to UDN CIDRs
3. Identify dependencies and communication patterns

#### Phase 2: Parallel Deployment
1. Deploy OSD cluster with BGP routing
2. Create UDNs matching legacy network segments
3. Establish connectivity between legacy and new environments

#### Phase 3: Gradual Migration
1. Migrate non-critical workloads first
2. Test connectivity thoroughly
3. Migrate in waves, maintaining IP addresses

#### Phase 4: Cutover
1. Update DNS entries
2. Redirect traffic to new environment
3. Decommission legacy infrastructure

---

## Cleanup Instructions

To remove all resources:

### Step 1: Delete OpenShift Resources

```bash
# Delete VMs
oc delete vm --all -n cudn-prod

# Delete namespace
oc delete namespace cudn-prod

# Delete ClusterUserDefinedNetwork
oc delete clusteruserdefinednetwork prod-udn

# Delete FRRConfiguration
oc delete frrconfiguration osd-bgp-config -n openshift-frr-k8s

# Disable route advertisements
oc patch Network.operator.openshift.io cluster --type=merge \
  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Disabled"}}}}'
```

### Step 2: Delete OSD Cluster

```bash
# Delete cluster via OCM
ocm delete cluster osd-bgp-cluster
```

### Step 3: Delete Google Cloud Infrastructure

```bash
# Remove BGP peers from Cloud Router
gcloud compute routers remove-bgp-peer osd-cloud-router \
  --peer-name=osd-router-zone-a \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

gcloud compute routers remove-bgp-peer osd-cloud-router \
  --peer-name=osd-router-zone-b \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

gcloud compute routers remove-bgp-peer osd-cloud-router \
  --peer-name=osd-router-zone-c \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Delete Cloud Router
gcloud compute routers delete osd-cloud-router \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Delete VPC peering
gcloud compute networks peerings delete osd-to-external \
  --network=osd-vpc \
  --project=YOUR_PROJECT_ID

gcloud compute networks peerings delete external-to-osd \
  --network=external-vpc \
  --project=YOUR_PROJECT_ID

# Delete firewall rules
gcloud compute firewall-rules delete allow-bgp-internal --project=YOUR_PROJECT_ID
gcloud compute firewall-rules delete allow-icmp-internal --project=YOUR_PROJECT_ID
gcloud compute firewall-rules delete allow-pod-egress --project=YOUR_PROJECT_ID

# Delete test VM
gcloud compute instances delete external-test-vm \
  --zone=us-central1-a \
  --project=YOUR_PROJECT_ID

# Delete subnets
gcloud compute networks subnets delete osd-subnet-zone-a --region=us-central1 --project=YOUR_PROJECT_ID
gcloud compute networks subnets delete osd-subnet-zone-b --region=us-central1 --project=YOUR_PROJECT_ID
gcloud compute networks subnets delete osd-subnet-zone-c --region=us-central1 --project=YOUR_PROJECT_ID
gcloud compute networks subnets delete external-subnet --region=us-central1 --project=YOUR_PROJECT_ID

# Delete VPCs
gcloud compute networks delete osd-vpc --project=YOUR_PROJECT_ID
gcloud compute networks delete external-vpc --project=YOUR_PROJECT_ID

# Delete reserved IPs
gcloud compute addresses delete bgp-router-ip-zone-a --region=us-central1 --project=YOUR_PROJECT_ID
gcloud compute addresses delete bgp-router-ip-zone-b --region=us-central1 --project=YOUR_PROJECT_ID
gcloud compute addresses delete bgp-router-ip-zone-c --region=us-central1 --project=YOUR_PROJECT_ID
```

---

## Key Differences from AWS Implementation

| Aspect | AWS (ROSA) | Google Cloud (OSD) |
|--------|------------|-------------------|
| BGP Service | AWS VPC Route Server | Google Cloud Router |
| VPC Interconnect | AWS Transit Gateway | VPC Peering / Cloud Interconnect |
| BGP Peer Setup | Automatic via Route Server endpoints | Manual BGP peer configuration on Cloud Router |
| Route Propagation | Automatic to route tables | Automatic via Cloud Router to VPC routes |
| Failover Mechanism | Route Server best path selection | Cloud Router best path selection |
| IP Address Management | IPAM via VPC | IPAM via VPC / Private Service Connect |

---

## References

- [Google Cloud Router Documentation](https://cloud.google.com/network-connectivity/docs/router)
- [OpenShift OVN-Kubernetes Documentation](https://docs.openshift.com/container-platform/latest/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html)
- [FRRouting Documentation](https://docs.frrouting.org/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [ROSA BGP Reference Implementation](https://github.com/msemanrh/rosa-bgp)

---

## Support and Troubleshooting

For issues or questions:
1. Check OpenShift Dedicated support via Red Hat Customer Portal
2. Review Google Cloud Router troubleshooting guides
3. Consult FRRouting community forums
4. File issues in internal documentation repository

---

**Document Version**: 1.0
**Last Updated**: 2026-03-17
**Author**: Cloud Infrastructure Team