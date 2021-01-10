# Deploy a Kubeadm+containerd multinode cluster in Azure with Terraform

This terraform templates create a single master node in Azure with Kubeadm + containerd + canal network plugin; it waits briefly for kubeadm to be installed then it creates a VMSS for the nodes. Within 5-10 minutes you should have a fully functional cluster.

Copy the file `terrafrom.tfvars.example` to `terraform.tfvars` and edit the values. Then just run:

```bash
terraform apply
```

(run a plan first to make sure you're happy with the result).

Notes:

- The script creates a private DNS zone so the nodes can resolve the IP of the controller automatically
- There is a need to delay the creation of the VMSS giving some time for the `kubeadm init` phase to complete
- the template generates a token in the form `"\\A([a-z0-9]{6})\\.([a-z0-9]{16})\\z"`