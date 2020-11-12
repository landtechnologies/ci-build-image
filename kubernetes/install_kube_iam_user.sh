#! /bin/bash

# Installs and uses a kubectl context which authenticates with the kubernetes cluster using IAM
# Args:
# --aws-profile <profile> - OPTIONAL
#   Will always use the profile with this name (in your aws creds) for authenticating with the cluster
#   Otherwise uses the current profile
# --cluster <cluster_name> - REQUIRED
#   Will set up the user and context for the given cluster
#   Otherwise will use whatever cluster is in the current context

set -eo pipefail

role="k8-admin"
aws_profile_env=null

for var in "$@"; do
  case "$var" in
  --aws-profile)
    aws_profile="$2"
    ;;
  --cluster)
    cluster_name="$2"
    ;;
  --role)
    role="$2"
    ;;
  esac
  shift
done

if [ -x "$cluster_name" ]; then
  echo "Cluster name (ie --cluster-name) not provided and is required"
  exit 1
fi

echo "Getting cluster ca data from credtash..."
cluster_ca_data=$(credstash get "k8/ca-data/$cluster_name" || echo "")

if [ "$cluster_ca_data" == "" ]; then
  echo "Could not get cluster ca data from credtash. Please ensure the ca data has been added to credtash under the key $credstash_key"
  exit 1
fi

if [ ! -f ~/.kube/config ]; then
  echo "$HOME/.kube/config not found. Generating one..."
  mkdir -p ~/.kube
  kubectl config view >~/.kube/config
fi

if [ -n "$aws_profile" ]; then
  export AWS_PROFILE="$aws_profile"
  aws_profile_env="
      - name: AWS_PROFILE
        value: $aws_profile
  "
fi

temp_user="$(mktemp)"
temp_config="$(mktemp)"

echo "
users:
- name: $cluster_name.iam
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      args:
      - token
      - -i
      - $cluster_name
      - -r
      - arn:aws:iam::$(aws account-id):role/$role
      command: aws-iam-authenticator
      env: $aws_profile_env" >"$temp_user"

echo "Merging generated config with defined config using KUBECONFIG var" # https://stackoverflow.com/a/56894036
export KUBECONFIG=~/.kube/config:$temp_user
kubectl config view --raw >"$temp_config"
mv "$temp_config" ~/.kube/config
rm -Rf "$temp_config"
unset KUBECONFIG

echo "Setting additional context values..."
kubectl config set-cluster "$cluster_name" --server "https://api.$cluster_name"
kubectl config set "clusters.$cluster_name.certificate-authority-data" "$cluster_ca_data"
kubectl config set-context "$cluster_name" --user "$cluster_name.iam" --cluster "$cluster_name"

echo "Using the newly generated context..."
kubectl config use-context "$cluster_name"
