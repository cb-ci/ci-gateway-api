#! /bin/bash


source .env
envsubst < eksctl-config.yaml.tpl > eksctl-config.yaml
eksctl create cluster \
    -f eksctl-config.yaml 
eksctl utils migrate-to-pod-identity --cluster=$CLUSTER_NAME --region=$AWS_DEFAULT_REGION --approve
aws eks update-kubeconfig --region $AWS_DEFAULT_REGION --name $CLUSTER_NAME
kubectl get nodes