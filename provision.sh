#!/bin/bash

set -e

export EDGE_HOST_NAME=$1
if [ -z "$EDGE_HOST_NAME" ]
then
  echo "Error: the script should be launched with edge host name parameter: ./provision.sh <edge-host-name> <edge-addr>"
  exit 1
fi

export EDGE_HOST_ADDR=$2
if [ -z "$EDGE_HOST_ADDR" ]
then
  echo "Error: the script should be launched with edge addr parameter: ./provision.sh <edge-host-name> <edge-addr>"
  exit 1
fi

if [ -z "$KUBECONFIG" ]
then
  echo "Error: \$KUBECONFIG is empty!"
  exit 1
fi

export K8S_API_ADDR=$(yq '.clusters[0].cluster.server' "$KUBECONFIG")
if [ -z "$K8S_API_ADDR" ]
then
  echo "Error: k8s API address is empty!"
  exit 1
fi

export K8S_CA=$(yq '.clusters[0].cluster.certificate-authority-data' "$KUBECONFIG") #| base64 -d | sed -e '1!s/^/    /')
if [ -z "$K8S_CA" ]
then
  echo "Error: k8s CA is empty!"
  exit 1
fi

export K8S_CLOUD_INIT_TOKEN=$(kubectl get secrets cloud-init-getter-token -n cloud-init-settings -ojsonpath='{.data.token}' | base64 -d)
if [ -z "$K8S_CLOUD_INIT_TOKEN" ]
then
  echo "Error: cloud-init-getter-token is empty!"
  exit 1
fi

export KUBE_VERSION=${KUBE_VERSION:-"1.26.4"}
echo "KUBE_VERSION: $KUBE_VERSION"

### bootstrap secret

# shellcheck disable=SC2016
bootstrap=$(envsubst '${EDGE_HOST_NAME} ${K8S_CLOUD_INIT_TOKEN} ${K8S_API_ADDR}' < ubuntu-bootstrap.template.yaml)

while read -r index; do
  bootstrap=$(printf '%s\n' "$bootstrap" | yq '.write_files['"$index"'].content = (.write_files['"$index"'].content | @base64)')
done < <(yq e '.write_files[] | key' ubuntu-bootstrap.template.yaml)

printf '%s\n' "$bootstrap" > ubuntu-bootstrap.generated.yaml

kubectl apply -n cloud-init-settings -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ubuntu-bootstrap-generic
type: Opaque
data:
  cloud-config: $(printf "%s" "$bootstrap" | base64 -w0)
EOF

### provision secret

# shellcheck disable=SC2016
provision=$(envsubst '${K8S_CLOUD_INIT_TOKEN} ${K8S_API_ADDR} ${K8S_CA}' < ubuntu-provision.template.yaml)

while read -r index; do
  # TODO: fix me
  # hack to prevent CA double encoding
  if [ "$index" -eq 9 ]; then
    continue
  fi
  provision=$(printf '%s\n' "$provision" | yq '.write_files['"$index"'].content = (.write_files['"$index"'].content | @base64)')
done < <(yq e '.write_files[] | key' ubuntu-provision.template.yaml)

printf '%s\n' "$provision" > ubuntu-provision.generated.yaml

kubectl apply -n cloud-init-settings -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ubuntu-provision-generic
type: Opaque
data:
  cloud-config: $(printf "%s" "$provision" | base64 -w0)
EOF

### bootstrap kubeconfig

export K8S_BOOTSTRAP_TOKEN=$(kubeadm token create)

kubectl apply -n cloud-init-settings -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kubelet-bootstrap-config
type: Opaque
data:
  kubeconfig: $(envsubst < kubeconfig-bootstrap.template.yaml | base64 -w0)
EOF

### cloud-init execution

scp ubuntu-bootstrap.generated.yaml root@"$EDGE_HOST_ADDR":/etc/cloud/cloud.cfg.d/ubuntu-bootstrap.cfg
ssh root@"$EDGE_HOST_ADDR" 'cloud-init clean && cloud-init --file /etc/cloud/cloud.cfg.d/ubuntu-bootstrap.cfg init && systemctl daemon-reload && systemctl restart bootstrap.service && systemctl daemon-reload'

### csr

# TODO: figure out why kubelet/api taints node as uninitialized
#kubectl taint nodes "$EDGE_HOST_NAME" node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule-
#kubectl certificate approve $(kubectl get csr -oname)