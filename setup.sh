#!/bin/bash

readinput () {
    # $1: name
    # $2: default value
    local VALUE
    read -p "${1} (default: ${2}): " VALUE
    VALUE="${VALUE:=${2}}"
    echo $VALUE
}

echo ""
echo "========================================================"
echo "|                   SCALE DEMO SETUP                   |"
echo "========================================================"
echo ""

# Disable warnings
az config set core.only_show_errors=yes

# Parameters
PREFIX=kubecon

LOCATION=`readinput "Location" "eastus"`
DNSZONE=`readinput "DNS Zone" "aks.azure.sabbour.me"`
DNSZONE_RESOURCEGROUP=`readinput "DNS Zone Resource Group" "azure.sabbour.me-rg"`
PREFIX=`readinput "Prefix" "${PREFIX}"`
RANDOMSTRING=`readinput "Random string" "$(mktemp --dry-run XXX | tr '[:upper:]' '[:lower:]')"`
IDENTIFIER="${PREFIX}${RANDOMSTRING}"

CLUSTER_RG=`readinput "Resource group" "${IDENTIFIER}-rg"`
CLUSTER_NAME="${IDENTIFIER}"
DEPLOYMENT_NAME="${IDENTIFIER}-deployment"
HOSTNAME="${IDENTIFIER}.${DNSZONE}"

#LATEST_K8S_VERSION=$(az aks get-versions --location ${LOCATION} --query "values[?isPreview == null] | sort_by(reverse(@), &version)[-1:].version" -o tsv)
AVAILABLE_K8S_VERSIONS=$(az aks get-versions --location ${LOCATION} --query "sort(values[?isPreview == null][].patchVersions.keys(@)[-1])" -o tsv | tr '\n' ',' | sed 's/,$//')
LATEST_K8S_VERSION=$(az aks get-versions --location ${LOCATION} --query "sort(values[?isPreview == null][].patchVersions.keys(@)[-1])[-1]" -o tsv)
K8S_VERSION=`readinput "Kubernetes version (${AVAILABLE_K8S_VERSIONS})" "${LATEST_K8S_VERSION}"`

AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
CURRENT_UPN=$(az account show --query user.name -o tsv) # Get current user's UPN (for role assignments)
CURRENT_OBJECT_ID=$(az ad user show --id ${CURRENT_UPN} --query id -o tsv) # Get current user's Object ID (for role assignments)

echo ""
echo "========================================================"
echo "|               ABOUT TO RUN THE SCRIPT                |"
echo "========================================================"
echo ""
echo "Will execute against subscription: ${AZURE_SUBSCRIPTION_ID}"
echo "To change, terminate the script, run az account set --subscription <subscrption id> and run the script again."
echo "Continue? Type y or Y."
read REPLY
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit
fi

echo ""
echo "========================================================"
echo "|               CONFIGURING PREREQUISITES              |"
echo "========================================================"
echo ""

START="$(date +%s)"
# Make sure the preview features are registered
echo "Making sure that the features are registered"
az extension add --upgrade --name aks-preview
az feature register --namespace Microsoft.ContainerService --name AKS-KedaPreview -o none
az feature register --namespace Microsoft.ContainerService --name AKS-VPAPreview -o none
az feature register --namespace "Microsoft.ContainerService" --name CiliumDataplanePreview -o none
az feature register --namespace "Microsoft.ContainerService" --name AzureOverlayPreview -o none
az feature register --namespace "Microsoft.ContainerService" --name EnableWorkloadIdentityPreview -o none

az provider register --namespace Microsoft.ContainerService -o none

echo ""
echo "========================================================"
echo "|                CREATING RESOURCE GROUP               |"
echo "========================================================"
echo ""

echo "Creating resource group ${CLUSTER_RG} in ${LOCATION}"
az group create -n ${CLUSTER_RG} -l ${LOCATION}

echo ""
echo "========================================================"
echo "|          CREATING AZURE MONITOR WORKSPACE            |"
echo "========================================================"
echo ""

echo "Creating Azure Monitor Workspace"
AZUREMONITORWORKSPACE_RESOURCE_ID=$(az monitor account create -n ${IDENTIFIER}  -g ${CLUSTER_RG}  --query id -o tsv)

echo ""
echo "Retrieving the Azure Monitor managed service for Prometheus query endpoint"
AZUREMONITOR_PROM_ENDPOINT=$(az resource show --id $AZUREMONITORWORKSPACE_RESOURCE_ID --query "properties.metrics.prometheusQueryEndpoint" -o tsv)
echo "Will later update the KEDA ScaledObject with this Prometheus query endpoint ${AZUREMONITOR_PROM_ENDPOINT}"

echo ""
echo "========================================================"
echo "|             CREATING AZURE MANAGED GRAFANA           |"
echo "========================================================"
echo ""

echo "Creating Azure Managed Grafana"
AZUREGRAFANA_ID=$(az grafana create -n ${IDENTIFIER}  -g ${CLUSTER_RG} --skip-role-assignments --query id -o tsv)
AZUREGRAFANA_PRINCIPALID=$(az resource show --id $AZUREGRAFANA_ID --query "identity.principalId" -o tsv)

echo "Granting Grafana Admin role assignment to ${CURRENT_UPN} (${CURRENT_OBJECT_ID})"
az role assignment create --assignee ${CURRENT_OBJECT_ID} --role "Grafana Admin" --scope ${AZUREGRAFANA_ID}

echo "Granting Monitoring Reader role assignment to Grafana on the Azure Monitor workspace"
az role assignment create --assignee ${AZUREGRAFANA_PRINCIPALID} --role "Monitoring Reader" --scope ${AZUREMONITORWORKSPACE_RESOURCE_ID}

echo "Granting Monitoring Reader role assignment to Grafana on the subscription"
az role assignment create --assignee ${AZUREGRAFANA_PRINCIPALID} --role "Monitoring Reader" --subscription ${AZURE_SUBSCRIPTION_ID}

echo "Sleeping to allow for identity to propagate"
sleep 60

echo ""
echo "========================================================"
echo "|                  CREATING AKS CLUSTER                |"
echo "========================================================"
echo ""

# Create AKS cluster with the required add-ons and configuration
echo "Creating an Azure Kubernetes Service cluster ${CLUSTER_NAME} with Kubernetes version ${K8S_VERSION}"
az aks create -n ${CLUSTER_NAME} -g ${CLUSTER_RG} \
--enable-azure-monitor-metrics \
--azure-monitor-workspace-resource-id ${AZUREMONITORWORKSPACE_RESOURCE_ID} \
--grafana-resource-id ${AZUREGRAFANA_ID} \
--enable-workload-identity \
--enable-oidc-issuer \
--enable-msi-auth-for-monitoring \
--enable-keda \
--node-vm-size Standard_DS4_v2 \
--enable-addons azure-keyvault-secrets-provider,web_application_routing \
--enable-secret-rotation \
--network-dataplane cilium \
--network-plugin azure \
--network-plugin-mode overlay \
--kubernetes-version ${LATEST_K8S_VERSION} \
--enable-cluster-autoscaler \
--min-count 1 \
--max-count 5

# Wait until the provisioning state of the cluster is not updating
echo "Waiting for the cluster to be ready"
while [[ "$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query 'provisioningState' -o tsv)" == "Updating" ]]; do
    sleep 10
done

echo ""
echo "Creating user node pools 1/4"
az aks nodepool add \
  -g ${CLUSTER_RG} \
  -n test1 \
  --cluster-name ${CLUSTER_NAME} \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 30 \
  --node-vm-size Standard_B4ms

echo ""
echo "Creating user node pools 2/4"
az aks nodepool add \
  -g ${CLUSTER_RG} \
  -n test2 \
  --cluster-name ${CLUSTER_NAME} \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 30 \
  --node-vm-size Standard_B4ms

echo ""
echo "Creating user node pools 3/4"
az aks nodepool add \
  -g ${CLUSTER_RG} \
  -n test3 \
  --cluster-name ${CLUSTER_NAME} \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 30 \
  --node-vm-size Standard_B4ms

echo ""
echo "Creating user node pools 4/4"
az aks nodepool add \
  -g ${CLUSTER_RG} \
  -n test4 \
  --cluster-name ${CLUSTER_NAME} \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 30 \
  --node-vm-size Standard_B4ms


echo ""
echo "========================================================"
echo "|         CONFIGURE WORKLOAD IDENTITY FOR KEDA         |"
echo "========================================================"
echo ""

# Create a managed identity for KEDA
echo "Creating a managed identity for KEDA"
az identity create -n keda-${CLUSTER_NAME} -g ${CLUSTER_RG}
echo ""
KEDA_UAMI_CLIENTID=$(az identity show -n keda-${CLUSTER_NAME} -g ${CLUSTER_RG} --query clientId -o tsv)
KEDA_UAMI_PRINCIPALID=$(az identity show -n keda-${CLUSTER_NAME} -g ${CLUSTER_RG} --query principalId -o tsv)
echo "Will later update the KEDA TriggerAuthentication to use this client identity ${KEDA_UAMI_CLIENTID}"
echo "Will later update the role assignment to use this principal identity ${KEDA_UAMI_PRINCIPALID}"

echo ""
echo "Sleeping to allow for identity to propagate"
sleep 30

# Create a federated identity credential for KEDA
echo ""
echo "Creating a federated identity credential for KEDA"
AKS_OIDC_ISSUER=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query "oidcIssuerProfile.issuerUrl" -o tsv)
az identity federated-credential create --name keda-${CLUSTER_NAME} --identity-name keda-${CLUSTER_NAME} --resource-group ${CLUSTER_RG} --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:kube-system:keda-operator

# Assigning the Monitoring Data Reader role to KEDA's managed identity
echo ""
echo "Assigning the Monitoring Data Reader role to KEDA's managed identity"
az role assignment create --assignee ${KEDA_UAMI_PRINCIPALID} --role "Monitoring Data Reader" --scope ${AZUREMONITORWORKSPACE_RESOURCE_ID}

echo ""
echo "========================================================"
echo "|             CONFIGURE APP ROUTER ADD-ON              |"
echo "========================================================"
echo ""

echo "Retrieving the app router add-on managed identity"
APPROUTER_IDENTITY_OBJECTID=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query ingressProfile.webAppRouting.identity.objectId -o tsv)

echo "Retrieving the Azure DNS zone ID for ${DNSZONE} in resource group ${DNSZONE_RESOURCEGROUP}"
AZUREDNS_ZONEID=$(az network dns zone show -n ${DNSZONE} -g ${DNSZONE_RESOURCEGROUP} --query "id" --output tsv)

echo "Assigning the DNS Zone Contributor role to the addon's managed identity"
az role assignment create --role "DNS Zone Contributor" --assignee $APPROUTER_IDENTITY_OBJECTID --scope $AZUREDNS_ZONEID

# Wait until the provisioning state of the cluster is not updating
echo "Waiting for the cluster to be ready"
while [[ "$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query 'provisioningState' -o tsv)" == "Updating" ]]; do
    sleep 10
done

echo "Updating the app router add-on to use the DNS Zone ${DNSZONE}"
az aks addon update -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --addon web_application_routing --dns-zone-resource-ids=$AZUREDNS_ZONEID

echo ""
echo "========================================================"
echo "|                    FINISHING UP                      |"
echo "========================================================"
echo ""

echo "Importing the nginx dashboards into Grafana"
az grafana dashboard import -n ${IDENTIFIER}  -g ${CLUSTER_RG} --definition @./grafana/nginx.json
az grafana dashboard import -n ${IDENTIFIER}  -g ${CLUSTER_RG} --definition @./grafana/request-handling-performance.json
az grafana dashboard create -n ${IDENTIFIER}  -g ${CLUSTER_RG} --definition @./grafana/demo-dashboard.json

# Retrieve Grafana dashboard URL
echo "Retrieving the Grafana dashboard URL"
GRAFANA_URL=$(az grafana show -n ${IDENTIFIER}  -g ${CLUSTER_RG} --query "properties.endpoint" -o tsv)

# Retrieve AKS cluster credentials
echo "Retrieving the Azure Kubernetes Service cluster credentials"
az aks get-credentials -n ${CLUSTER_NAME} -g ${CLUSTER_RG}

END="$(date +%s)"
DURATION=$[ ${END} - ${START} ]

echo ""
echo "========================================================"
echo "|                   SETUP COMPLETED                    |"
echo "========================================================"
echo ""
echo "Total time elapsed: $(( DURATION / 60 )) minutes"

echo ""
echo "========================================================"
echo "|                  UPDATING MANIFESTS                  |"
echo "========================================================"
echo ""
echo "Updating the manifests/scaledobject.yaml file with Prometheus query endpoint > manifests/generated/scaledobject.yaml "
yq "(.spec.triggers.[] | select(.type == \"prometheus\")).metadata.serverAddress |= \"${AZUREMONITOR_PROM_ENDPOINT}\"" manifests/scaledobject.yaml > manifests/generated/scaledobject.yaml
echo "Updating the manifests/triggerauthentication.yaml file with KEDA client id > manifests/generated/triggerauthentication.yaml"
yq "(.spec.podIdentity.identityId) |= \"${KEDA_UAMI_CLIENTID}\"" manifests/triggerauthentication.yaml > manifests/generated/triggerauthentication.yaml
echo "Updating the manifests/ingress.yaml file with hostname > manifests/generated/ingress.yaml"
yq "(.spec.rules[0]).host |= \"${HOSTNAME}\"" manifests/ingress.yaml > manifests/generated/ingress.yaml

echo ""
echo "========================================================"
echo "|       DEPLOYING THE PROMETHEUS SCRAPING CONFIG       |"
echo "========================================================"
echo ""
kubectl apply -f ./manifests/config/ama-metrics-settings.config.yaml

echo ""
echo "========================================================"
echo "|               DEPLOYING THE APPLICATION              |"
echo "========================================================"
echo ""
kubectl apply -f ./manifests/namespace.yaml
kubectl apply -f ./manifests/deployment.yaml
kubectl apply -f ./manifests/service.yaml
kubectl apply -f ./manifests/pdb.yaml
kubectl apply -f ./manifests/generated/ingress.yaml
kubectl apply -f ./manifests/generated/triggerauthentication.yaml
kubectl apply -f ./manifests/generated/scaledobject.yaml

# Force a restart for the keda operator deployment to pick up the new trigger authentication
kubectl rollout restart deployment.apps/keda-operator -n kube-system

echo ""
echo "========================================================"
echo "|                GETTING THE ENDPOINTS                 |"
echo "========================================================"
echo ""
INGRESS_IP=""
echo "Waiting for the ingress to get an IP address"
while [ -z $INGRESS_IP ]
do
    INGRESS_IP=$(kubectl get ingress serverloader --namespace=serverloader -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    sleep 5
done

echo "Waiting for the A record to be created in the DNS zone"
while [[ "$(az network dns record-set a list -g ${DNSZONE_RESOURCEGROUP} -z ${DNSZONE} --query "[?name=='${IDENTIFIER}'].provisioningState" -o tsv)" != "Succeeded" ]]; do
    sleep 5
done

echo ""
echo "========================================================"
echo "|                 TEST THE APPLICATION                 |"
echo "========================================================"
echo ""
echo "curl -k http://${INGRESS_IP}/workout -H \"Host: ${HOSTNAME}\""
echo "curl -k http://${INGRESS_IP}/metrics -H \"Host: ${HOSTNAME}\""
echo "curl -k http://${INGRESS_IP}/stats -H \"Host: ${HOSTNAME}\""
echo ""
echo "curl -k http://${HOSTNAME}/workout"
echo "curl -k http://${HOSTNAME}/metrics"
echo "curl -k http://${HOSTNAME}/stats"
echo ""
echo "Grafana dashboard: ${GRAFANA_URL}"
echo ""
echo ""
echo "========================================================"
echo "|               CLEAN UP AFTER YOU ARE DONE            |"
echo "========================================================"
echo ""
echo "Delete the ${CLUSTER_RG} resource group when you are done by running:"
echo "az group delete --name ${CLUSTER_RG} --no-wait"
echo ""
echo "Delete the ${HOSTNAME} records when you are done by running:"
echo "az network dns record-set a delete -g ${DNSZONE_RESOURCEGROUP} -z ${DNSZONE} -n ${IDENTIFIER}"
echo "az network dns record-set txt delete -g ${DNSZONE_RESOURCEGROUP} -z ${DNSZONE} -n ${IDENTIFIER}"
echo ""
echo "Have fun!"

# Enable warnings
az config set core.only_show_errors=no
