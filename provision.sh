#!/bin/bash

set -eo pipefail

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

export K8S_CA=$(yq '.clusters[0].cluster.certificate-authority-data' "$KUBECONFIG")
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

bootstrap=$(envsubst < ubuntu-bootstrap.template.yaml)

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

provision=$(envsubst < ubuntu-provision.template.yaml)

while read -r index; do
  provision=$(printf '%s\n' "$provision" | yq '.write_files['"$index"'].content = (.write_files['"$index"'].content | @base64)')
done < <(yq e '.write_files[] | key' ubuntu-provision.template.yaml)

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

token_id="edge-generic"
# TODO: fix me
# there is a chance of repeated tokens
export K8S_BOOTSTRAP_TOKEN_SECRET=$(sed 's/[-]//g' < /proc/sys/kernel/random/uuid | head -c 16)

kubectl apply -n kube-system -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-$token_id
type: bootstrap.kubernetes.io/token
data:
  description: $(echo "default bootstrap token for edge device provisioning" | base64 -w0)
  token-id: $(echo "$token_id" | base64 -w0)
  token-secret: $(echo "$K8S_BOOTSTRAP_TOKEN_SECRET" | base64 -w0)
  usage-bootstrap-authentication: $(echo "true" | base64 -w0)
  usage-bootstrap-signing: $(echo "true" | base64 -w0)
  auth-extra-groups: $(echo "system:bootstrappers:worker,system:bootstrappers:ingress" | base64 -w0)
EOF

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
ssh root@"$EDGE_HOST_ADDR" 'cloud-init clean && cloud-init --file /etc/cloud/cloud.cfg.d/ubuntu-bootstrap.cfg init'
