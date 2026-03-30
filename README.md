--

```markdown
# 🚀 deployment-documentation

## Azure Kubernetes Service (AKS) Deployment Workflow

Post pushing the code to the ADO repository, we have followed the following steps to achieve a seamless deployment to AKS without issues.

### 1. CI/CD Pipeline Configuration (Azure DevOps)
We created an `azure-pipelines.yml` file to automate the delivery process. The pipeline consists of two primary stages:

* **Build Stage:** * Uses a multi-stage **Dockerfile** to compile the .NET 8 application.
    * Builds the image and pushes it to our private **Azure Container Registry (ACR)**.
* **Deploy Stage:** * Connects to the AKS cluster using a Service Connection.
    * Injects the specific image tag from the build into the Kubernetes manifest.
    * Applies the manifests to the cluster to update the application.

### 2. Kubernetes Manifest Strategy
To expose our application, we defined two key YAML configurations:

* **Deployment (`deployment.yml`):** Manages the Pods and ensures the correct Docker image version is running. We configured `replicas: 1` initially to verify stability.
* **Service (`services.yml`):** Uses `type: LoadBalancer` to provision an External IP, allowing traffic to reach the pods on port `8080`.

### 3. Critical Permission Setup (The "Bridge")
A crucial step to ensure the deployment didn't fail with `ImagePullBackOff` errors was connecting our Registry to our Cluster.

By default, AKS cannot pull images from a private ACR. We resolved this by granting the necessary permissions using the Azure CLI:

```bash
# This command attaches the ACR to AKS, granting the 'AcrPull' permission
az aks update -n masterscluster -g mastervijay --attach-acr master1regestry

```

*Note: This was a one-time setup that prevented "0/1 Ready" and permission errors.*

### 4. Verification & Troubleshooting

After the pipeline ran successfully, we verified the deployment using the following checks:

1. **Pod Status:** Checked **Workloads** in the Azure Portal to ensure the Pod status was **Running (1/1)** and not stuck in a loop or showing a warning triangle.
2. **External IP:** Verified that the Load Balancer generated a public IP address.
3. **File Paths:** Ensured our pipeline script correctly referenced the YAML files (e.g., using `./deployment.yml` instead of `k8s/deployment.yml` if files are in the root).

### 5. Outcome

Following this structured approach, the application was successfully containerized, pushed to the registry, and deployed to the Kubernetes cluster with a working public endpoint.

```

```
