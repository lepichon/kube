<!-- TOC depthFrom:1 depthTo:6 withLinks:1 updateOnSave:1 orderedList:0 -->

- [Kubernetes cluster resources monitor cli](#kubernetes-cluster-resources-monitor-cli)
- [Description](#description)
	- [Cluster Level:](#cluster-level)
	- [Node Level](#node-level)
	- [Pod level](#pod-level)
- [Requirements](#requirements)
- [Usage](#usage)
	- [Help](#help)
- [TODO](#todo)

<!-- /TOC -->

# Kubernetes cluster resources monitor cli

# Description

Cli to display the used/deployed resources of a Kubernetes cluster.

## Cluster Level:

Cluster total deployed resources :
* node count
* total memory
* total vcpu(s),
* total pv
* nodes flavor

```
k8s_cluster_monitor.sh -c
```
```
Nodes count : 79
Total Nodes Memory : 6,7Ti (7281813356544 bytes)
Total Nodes vCPUs : 1264
Total PVC : 51Ti (55609089064960 bytes)
Nodes flavors:
                 - 20: n1-standard-8
                 - 49: n1-highmem-16
                 - 10: n1-standard-32
```

## Node Level
* vCPUs Request and Limits Used and Left by node
* Memory Request and Limits Used and Left by node

```
k8s_cluster_monitor.sh -n
```
```
=============================================      ==========     ==========     ==========     ==========               ==========               ==========
NODES Hostname                                     CPU Req        CPU Lim        CPU Lim Left   Memory Req               Memory Lim               Memory Lim Left
---------------------------------------------      ----------     ----------     ----------     ----------               ----------               ----------
gke-project-name-app1-862ca784-158r                7401m (93%)    9153m (115%)   -1193m (-15%)  17320Mi (65%)            17604Mi (66%)            9068Mi (34%)
gke-project-name-app1-862ca784-2tl0                7401m (93%)    9153m (115%)   -1193m (-15%)  17320Mi (65%)            17604Mi (66%)            9068Mi (34%)
gke-project-name-app1-862ca784-38h6                7401m (93%)    9153m (115%)   -1193m (-15%)  17320Mi (65%)            17604Mi (66%)            9068Mi (34%)
gke-project-name-app1-862ca784-6jbs                7401m (93%)    9153m (115%)   -1193m (-15%)  17320Mi (65%)            17604Mi (66%)            9068Mi (34%)
gke-project-name-app1-862ca784-6tb8                7401m (93%)    9153m (115%)   -1193m (-15%)  17320Mi (65%)            17604Mi (66%)            9068Mi (34%)
.............................................................................................................
gke-project-app2-e354702e-xtnv                     15601m (98%)   17753m (111%)  -1759m (-11%)  42200570265600m (41%)    41656Mi (43%)            55218Mi (57%)
gke-project-app2-e354702e-z75b                     15701m (98%)   18753m (118%)  -2860m (-18%)  57756Mi (59%)            60088Mi (62%)            36828Mi (38%)
gke-project-app2-e354702e-zls8                     13101m (82%)   14753m (92%)   1282m (8%)     78236Mi (80%)            78520Mi (81%)            18418Mi (19%)
gke-project-infra-ad8399f3-m1z1                    18461m (57%)   19253m (60%)   12835m (40%)   87062Mi (77%)            87406Mi (78%)            24652Mi (22%)
gke-project-infra-ad8399f3-nr7d                    21461m (67%)   23253m (73%)   8600m (27%)    95254Mi (85%)            95598Mi (85%)            16870Mi (15%)
gke-project-infra-ad8399f3-pmfh                    21201m (66%)   23253m (73%)   8600m (27%)    91048Mi (81%)            91332Mi (81%)            21423Mi (19%)
gke-project-infra-ad8399f3-rj8t                    20521m (64%)   23253m (73%)   8600m (27%)    86598Mi (77%)            86882Mi (77%)            25951Mi (23%)
---------------------------------------------      ----------     ----------     ----------     ----------               ----------               ----------
Total 79 nodes resources usage :                   AVG: 86%       AVG: 98%       AVG: 1%        AVG: 59%                 AVG: 60%                 AVG: 39%
```

## Pod level
Deployed pods list by namespace highlighting status
* Pod names by namespace
* Ready status
* Running Status
* Restart number
* Lifetime

```
k8s_cluster_monitor.sh -p
```
![Pods display](img/monitor-workload-pods.png)

# Requirements

* The user must be authenticated on the Kubernetes cluster.
* The user must have node and pod describe privileges
* Kubectl >= 1.11 is requierd
  previous kubectl version are supported in older versions of this script

# Usage

Without any option the script will watch nodes and pods resources

Edit the script to configure the selected namespaces in `MONITORED_NS` array for `-w` option.
```
ex: MONITORED_NS=(kube-system rabbitmq es-cluster)
```

## Help

```
Usage: k8s_cluster_monitor.sh [options...]                                                                                                                              

No option will whatch for nodes and pod resources on all available namespaces

  -w    Filter Pods from configurated namespaces only
  -c    Display Clusters deployed resources and exit
  -n    Display Nodes used resources informations and exit
  -p    Watch only Pods deployed resources informations
  -h    Display this help

  To define pods namespaces filtering with "-w",
  edit the MONITORED_NS array in script.
```
---


# TODO

* Namespace include list as argument
* See `kubect top` integration for pod resources consumption (need cadvisor metrics enabled)
