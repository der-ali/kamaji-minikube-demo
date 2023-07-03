#!/bin/bash - 
#===============================================================================
#
#          FILE: setup.sh
# 
#         USAGE: ./setup.sh 
# 
#   DESCRIPTION: Establish a flat network between two Kubernetes clusters' resources by leveraging the capabilities of Calico, along with BGP reflectors.
# 
#  REQUIREMENTS: minikube, calico
#        AUTHOR: Ali Akil (), 
#       CREATED: 06/26/2023 11:41
#===============================================================================

# Treat unset variables as an error
set -o nounset

declare -A clusters
clusters[cluster1]="10.200.0.0/16 10.201.0.0/16 2"


provision_minikube() {
  local values=(${clusters[cluster1]})
  local pod_network_cidr=${values[0]}
  local service_cluster_ip_range=${values[1]}
  local nodes=${values[2]}
  minikube -p cluster1 start  --extra-config=kubeadm.pod-network-cidr=${pod_network_cidr} --service-cluster-ip-range=${service_cluster_ip_range} --network=calico_cluster_peer_demo --container-runtime=containerd --nodes ${nodes} --driver=kvm --cpus 3 --memory 4048 --wait=all --cni=calico
}

deploy_metallb() {
  METALLB_VER=$(curl "https://api.github.com/repos/metallb/metallb/releases/latest" | jq -r ".tag_name")
  kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VER}/config/manifests/metallb-native.yaml"
  kubectl wait pods -n metallb-system -l app=metallb,component=controller --for=condition=Ready --timeout=10m
  kubectl wait pods -n metallb-system -l app=metallb,component=speaker --for=condition=Ready --timeout=2m
  kubectl apply -f metallb-address-pool.yaml
}

deploy_kubevirt() {
  local VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases | grep tag_name | grep -v -- '-rc' | sort -r | head -1 | awk -F': ' '{print $2}' | sed 's/,//' | xargs)
  kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-operator.yaml  --dry-run=client -o yaml | kubectl apply -f -
  kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-cr.yaml  --dry-run=client -o yaml | kubectl apply -f -
  kubectl wait -n kubevirt kv kubevirt --for=condition=Available --timeout=10m

}

deploy_cert_manager() {
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm install \
    cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.11.0 \
    --set installCRDs=true
}

deploy_kamaji() {
  helm repo add clastix https://clastix.github.io/charts
  helm repo update
  helm install kamaji clastix/kamaji -n kamaji-system --create-namespace
}

configure_capi() {
clusterctl init --infrastructure kubevirt
clusterctl init --control-plane kamaji
}

# Function to check if a Kubernetes node is healthy
check_node_health() {
  local node=$1
  local cluster=$2
  local health_status=$(kubectl --cluster=$cluster get node $node -o jsonpath='{range @.status.conditions[-1:]}{.status}{end}')

  if [[ "$health_status" != "True" ]]; then
      echo "Node $node is not healthy!"
      exit 1
  else
      echo "Node $node is healthy."
  fi
}

check_nodes_health() {
  # Loop through each node and check its health
  local cluster="cluster1"
  local nodes=$(get_nodes ${cluster})

  for node in $nodes; do
    check_node_health ${node} ${cluster}
  done
}


get_nodes() {
  local cluster="cluster1"
  kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}


# exports the environment variables in the bgp-other-cluster.yaml template to be consumed by envsubst
#define_template_vars() {
#  # Second iteration needed for the environment variables inside bgp-other-cluster.yaml
#  # During the first iteration over cluster2 the values for the env vars of cluster1 are not yet available.
#  for cluster in "${!clusters[@]}"; do
#    local rr_nodes_ip=($(get_rr_nodes_ips $cluster))
#    local rr_nodes=($(get_rr_nodes $cluster))
#    declare -A rr_nodes_map
#    rr_nodes_map[${rr_nodes[0]}]=${rr_nodes_ip[0]}
#    rr_nodes_map[${rr_nodes[1]}]=${rr_nodes_ip[1]}
#    for rr_node in "${!rr_nodes_map[@]}"; do
#      # Convert the node names to uppercase and subst '-' by '_' to match the env vars naming
#      local tmp=${rr_node^^}
#      local rr_node_var=${tmp//-/_}_IP
#      # Output example: 
#      # $rr_node_var=CLUSTER2_M03_IP
#      # $CLUSTER2_M03_IP=192.168.39.203
#      export $rr_node_var=${rr_nodes_map[$rr_node]}
#    done
#  done
#}


#template_config_files() {
#  local cluster=$1
#  envsubst < ${cluster}_calicomanifests/bgp-other-cluster.yaml
#}

#apply_templates() {
#  local cluster=$1
#  local config=$(template_config_files $cluster)
#  kubectl config use-context $cluster
#  calicoctl apply -f - <<< ${config}
#}

provision_minikube 
check_nodes_health
deploy_kubevirt
deploy_metallb
