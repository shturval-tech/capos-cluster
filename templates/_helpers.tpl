{{/*
Expand the name of the chart.
*/}}
{{- define "capos-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "capos-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "capos-cluster.labels" -}}
helm.sh/chart: {{ include "capos-cluster.chart" . }}
{{ include "capos-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "capos-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capos-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
OpenStack identity secret name — defaults to Release.Name if not set
*/}}
{{- define "capos-cluster.identitySecretName" -}}
{{- default .Release.Name .Values.capos.identitySecretName }}
{{- end }}

{{/*
clouds.yaml content as base64 — wraps capos.cloudsYaml under clouds.<cloudName>.
*/}}
{{- define "capos-cluster.cloudsYaml.b64" -}}
{{- dict "clouds" (dict .Values.capos.cloudName .Values.capos.cloudsYaml) | toYaml | b64enc }}
{{- end }}

{{/*
Read the ClusterConfig secret value
*/}}
{{- define "capos-cluster.clusterConfig" -}}
{{- tpl (.Files.Get .Values.clusterConfigFile) . | b64enc | quote }}
{{- end }}

{{/*
etcd external CA cert
*/}}
{{- define "capos-cluster.etcd.caCrt" -}}
{{- if .Values.etcd.external.caCrt }}
{{- .Files.Get .Values.etcd.external.caCrt | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
etcd external client cert
*/}}
{{- define "capos-cluster.etcd.apiCrt" -}}
{{- if .Values.etcd.external.apiCrt }}
{{- .Files.Get .Values.etcd.external.apiCrt | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
etcd external client key
*/}}
{{- define "capos-cluster.etcd.apiKey" -}}
{{- if .Values.etcd.external.apiKey }}
{{- .Files.Get .Values.etcd.external.apiKey | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Raw encryption key material (32 chars). Same contract as backend/cluster-manager/capsm:
  Secret.data["secret"] (after decode) == raw key
  EncryptionConfiguration aescbc.keys[].secret == base64(raw key)
Cached in Values._encryptionKey for one helm render so Secret and NCI always match.
*/}}
{{- define "capos-cluster.encryptionKeyMaterial" -}}
{{- if not .Values._encryptionKey -}}
{{- $key := "" -}}
{{- $secretName := printf "%s-encryption-configuration" .Release.Name -}}
{{- $existing := lookup "v1" "Secret" .Release.Name $secretName -}}
{{- if and $existing $existing.data $existing.data.secret -}}
{{- $key = index $existing.data "secret" | b64dec -}}
{{- else -}}
{{- $key = sha256sum (printf "%s-encryption-key" .Release.Name) | trunc 32 -}}
{{- end -}}
{{- $_ := set .Values "_encryptionKey" $key -}}
{{- end -}}
{{- .Values._encryptionKey -}}
{{- end -}}

{{/*
Backward-compatible alias: raw key material (NOT base64).
*/}}
{{- define "capos-cluster.encryptionKey" -}}
{{- include "capos-cluster.encryptionKeyMaterial" . -}}
{{- end -}}

{{/*
Content of /etc/kubernetes/secrets_encryption.yaml — format matches cluster-manager
pkg/nodeconfig/generator/security.go encryptionConfiguration().
*/}}
{{- define "capos-cluster.secretsEncryptionContent" -}}
---
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    providers:
    - aescbc:
        keys:
          - name: key1
            secret: {{ include "capos-cluster.encryptionKeyMaterial" . | b64enc }}
    - identity: {}
{{- end -}}

{{/*
Generate nci.json (ShturvalInit) as base64-encoded JSON.
Usage: include "capos-cluster.nci.json.b64" (dict "ctx" . "controlplane" true)
  controlplane=true  — adds secrets_encryption, audit_policy, etcd certs
  controlplane=false — directories and system config only (workers)
*/}}
{{- define "capos-cluster.nci.json.b64" -}}
{{- $ctx := .ctx -}}
{{- $nciCtx := dict
  "Values"       $ctx.Values
  "Files"        $ctx.Files
  "Release"      $ctx.Release
  "Chart"        $ctx.Chart
  "controlplane" .controlplane
-}}
{{- tpl ($ctx.Files.Get "conf/nci.yaml") $nciCtx | fromYaml | toJson | b64enc -}}
{{- end }}

{{/*
Generate monitoringid
*/}}
{{- define "capos-cluster.monitoringid" -}}
{{ adler32sum .Release.Name | int }}
{{- end }}

{{/*
Minimal KubeletConfiguration YAML — base64-encoded for injection via preKubeadmCommands.
*/}}
{{- define "capos-cluster.kubelet.b64" -}}
{{- $cfg := `---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
protectKernelDefaults: true
` -}}
{{- $cfg | b64enc }}
{{- end }}

{{/*
kube-apiserver extra args.
Audit/encryption args only when secure=true.
*/}}
{{- define "capos-cluster.apiserver" -}}
extraArgs:
{{- if .Values.secure }}
- name: audit-log-maxage
  value: "30"
- name: audit-log-maxbackup
  value: "10"
- name: audit-log-maxsize
  value: "100"
- name: audit-log-mode
  value: batch
- name: audit-log-path
  value: /var/log/kube-api-audit/audit.log
- name: audit-policy-file
  value: "{{ .Values.auditPolicy.location }}"
- name: encryption-provider-config
  value: /etc/kubernetes/secrets_encryption.yaml
{{- end }}
- name: authorization-mode
  value: Node,RBAC
- name: default-not-ready-toleration-seconds
  value: "30"
- name: default-unreachable-toleration-seconds
  value: "30"
- name: kubelet-certificate-authority
  value: /etc/kubernetes/pki/ca.crt
- name: profiling
  value: "false"
- name: request-timeout
  value: 60s
- name: tls-min-version
  value: VersionTLS13
{{- end }}

{{/*
kube-controller-manager extra args
*/}}
{{- define "capos-cluster.controllerManager" -}}
controllerManager:
  extraArgs:
  - name: bind-address
    value: 0.0.0.0
  - name: node-monitor-grace-period
    value: 20s
  - name: node-monitor-period
    value: 2s
  - name: profiling
    value: "false"
  - name: terminated-pod-gc-threshold
    value: "10"
  - name: tls-min-version
    value: VersionTLS13
{{- end }}

{{/*
kube-scheduler extra args
*/}}
{{- define "capos-cluster.scheduler" -}}
scheduler:
  extraArgs:
  - name: bind-address
    value: 0.0.0.0
  - name: profiling
    value: "false"
{{- end }}

{{/*
Effective flavor for control plane — falls back to capos.flavor
*/}}
{{- define "capos-cluster.master.flavor" -}}
{{- default .Values.capos.flavor .Values.master.flavor }}
{{- end }}

{{/*
Resolve default image name from capos.kubeTemplates by kubeVersion.
Supports kubeVersion with and without "v" prefix.
*/}}
{{- define "capos-cluster.defaultImage" -}}
{{- $kubeVersion := .Values.kubeVersion | toString | trim -}}
{{- $normalizedVersion := printf "v%s" (trimPrefix "v" $kubeVersion) -}}
{{- $defaultImage := get .Values.capos.kubeTemplates $normalizedVersion -}}
{{- required (printf "capos.kubeTemplates must contain image for Kubernetes version %s" $normalizedVersion) $defaultImage -}}
{{- end }}

{{/*
Effective image name for control plane.
*/}}
{{- define "capos-cluster.master.image" -}}
{{- default (include "capos-cluster.defaultImage" .) .Values.master.image }}
{{- end }}

{{/*
Effective SSH key name for control plane — falls back to capos.sshKeyName
*/}}
{{- define "capos-cluster.master.sshKeyName" -}}
{{- default .Values.capos.sshKeyName .Values.master.sshKeyName }}
{{- end }}

{{/*
Control plane availability zones as wrapped YAML map {azs: [...]}.
fromYaml cannot unmarshal a bare YAML list, so we wrap in a dict.
Priority:
1) capos.controlPlaneAZ (list or non-empty string)
2) capos.availabilityZones
3) empty list
Usage: (include "capos-cluster.controlPlaneAZListYaml" . | fromYaml).azs | default (list)
*/}}
{{- define "capos-cluster.controlPlaneAZListYaml" -}}
{{- $azs := list -}}
{{- if and (kindIs "slice" .Values.capos.controlPlaneAZ) (gt (len .Values.capos.controlPlaneAZ) 0) }}
{{- $azs = .Values.capos.controlPlaneAZ -}}
{{- else if and (not (kindIs "slice" .Values.capos.controlPlaneAZ)) .Values.capos.controlPlaneAZ }}
{{- $azs = list .Values.capos.controlPlaneAZ -}}
{{- else if .Values.capos.availabilityZones }}
{{- $azs = .Values.capos.availabilityZones -}}
{{- end }}
{{- toYaml (dict "azs" $azs) -}}
{{- end }}

{{/*
Single default AZ for control plane machine/root volume.
Priority:
1) first element of capos.controlPlaneAZ (if list) or capos.controlPlaneAZ (if string)
2) first element of capos.availabilityZones
3) empty string
*/}}
{{- define "capos-cluster.controlPlanePrimaryAZ" -}}
{{- if and (kindIs "slice" .Values.capos.controlPlaneAZ) (gt (len .Values.capos.controlPlaneAZ) 0) -}}
  {{- index .Values.capos.controlPlaneAZ 0 -}}
{{- else if and (not (kindIs "slice" .Values.capos.controlPlaneAZ)) .Values.capos.controlPlaneAZ -}}
  {{- .Values.capos.controlPlaneAZ -}}
{{- else if and (kindIs "slice" .Values.capos.availabilityZones) (gt (len .Values.capos.availabilityZones) 0) -}}
  {{- index .Values.capos.availabilityZones 0 -}}
{{- else -}}
  {{- "" -}}
{{- end -}}
{{- end }}

{{/*
Worker availability zones as wrapped YAML map {azs: [...]}.
fromYaml cannot unmarshal a bare YAML list, so we wrap in a dict.
Priority:
1) capos.defaultWorkerAZ (list or non-empty string)
2) capos.availabilityZones
3) empty list
Usage: (include "capos-cluster.workerAZListYaml" . | fromYaml).azs | default (list)
*/}}
{{- define "capos-cluster.workerAZListYaml" -}}
{{- $azs := list -}}
{{- if and (kindIs "slice" .Values.capos.defaultWorkerAZ) (gt (len .Values.capos.defaultWorkerAZ) 0) }}
{{- $azs = .Values.capos.defaultWorkerAZ -}}
{{- else if and (not (kindIs "slice" .Values.capos.defaultWorkerAZ)) .Values.capos.defaultWorkerAZ }}
{{- $azs = list .Values.capos.defaultWorkerAZ -}}
{{- else if .Values.capos.availabilityZones }}
{{- $azs = .Values.capos.availabilityZones -}}
{{- end }}
{{- toYaml (dict "azs" $azs) -}}
{{- end }}

{{/*
Single default AZ for workers (failureDomain).
Priority:
1) first element of capos.defaultWorkerAZ (if list) or capos.defaultWorkerAZ (if string)
2) empty string — capos.availabilityZones is NOT used as fallback here, because it describes
   all available AZs for the cloud (used for control plane distribution and UI), not a
   default placement for workers. If no explicit AZ is configured, let OpenStack decide.
*/}}
{{- define "capos-cluster.workerPrimaryAZ" -}}
{{- if and (kindIs "slice" .Values.capos.defaultWorkerAZ) (gt (len .Values.capos.defaultWorkerAZ) 0) -}}
  {{- index .Values.capos.defaultWorkerAZ 0 -}}
{{- else if and (not (kindIs "slice" .Values.capos.defaultWorkerAZ)) .Values.capos.defaultWorkerAZ -}}
  {{- .Values.capos.defaultWorkerAZ -}}
{{- else -}}
  {{- "" -}}
{{- end -}}
{{- end }}

{{/*
Comma-separated availability zones for provider annotations.
Uses capos.availabilityZones if set, otherwise derives from controlPlaneAZ and defaultWorkerAZ.
*/}}
{{- define "capos-cluster.availabilityZones" -}}
{{- if .Values.capos.availabilityZones }}
{{- join "," .Values.capos.availabilityZones }}
{{- else }}
{{- $azs := list }}
{{- $controlPlaneAZs := (include "capos-cluster.controlPlaneAZListYaml" . | fromYaml).azs | default (list) }}
{{- range $az := $controlPlaneAZs }}
{{- if and $az (not (has $az $azs)) }}
{{- $azs = append $azs $az }}
{{- end }}
{{- end }}
{{- $workerAZs := (include "capos-cluster.workerAZListYaml" . | fromYaml).azs | default (list) }}
{{- range $az := $workerAZs }}
{{- if and $az (not (has $az $azs)) }}
{{- $azs = append $azs $az }}
{{- end }}
{{- end }}
{{- join "," $azs }}
{{- end }}
{{- end }}

{{/*
Comma-separated allowed flavors for provider annotations.
Uses capos.allowedFlavors if set, otherwise falls back to capos.flavor.
*/}}
{{- define "capos-cluster.allowedFlavors" -}}
{{- if .Values.capos.allowedFlavors }}
{{- join "," .Values.capos.allowedFlavors }}
{{- else if .Values.capos.flavor }}
{{- .Values.capos.flavor }}
{{- end }}
{{- end }}

{{/*
Comma-separated allowed volume types for provider annotations.
Uses capos.allowedVolumeTypes if set, otherwise falls back to capos.rootVolume.type.
*/}}
{{- define "capos-cluster.allowedVolumeTypes" -}}
{{- if .Values.capos.allowedVolumeTypes }}
{{- join "," .Values.capos.allowedVolumeTypes }}
{{- else if .Values.capos.rootVolume.type }}
{{- .Values.capos.rootVolume.type }}
{{- end }}
{{- end }}

{{/*
Сеть узлов OpenStackCluster.

Если задан capos.network.id или capos.network.name — существующая сеть:
пишется spec.network (и при необходимости spec.subnets), managedSubnets нет,
контроллер сеть не создаёт. Иначе — managedSubnets из managedSubnetCIDR.
*/}}
{{- define "capos-cluster.openstackClusterNetwork" -}}
{{- $network := .Values.capos.network | default dict -}}
{{- $networkID := trim (toString ($network.id | default "")) -}}
{{- $networkName := trim (toString ($network.name | default "")) -}}
{{- if and (ne $networkID "") (ne $networkName "") -}}
{{- fail "capos.network: укажите только id или name, не оба сразу" -}}
{{- end -}}
{{- $useExisting := or (ne $networkID "") (ne $networkName "") -}}
{{- $subnets := .Values.capos.subnets | default (list) -}}
{{- if and (gt (len $subnets) 0) (not $useExisting) -}}
{{- fail "capos.subnets заданы без capos.network: подсети указываются только для уже существующей сети" -}}
{{- end -}}
{{- if gt (len $subnets) 2 -}}
{{- fail "capos.subnets: не больше двух подсетей (одна IPv4 и одна IPv6)" -}}
{{- end -}}
{{- if $useExisting -}}
network:
{{- if ne $networkID "" }}
  id: {{ $networkID | quote }}
{{- else }}
  filter:
    name: {{ $networkName | quote }}
{{- end }}
{{- if gt (len $subnets) 0 }}
subnets:
{{- range $i, $subnet := $subnets }}
{{- $sid := trim (toString ($subnet.id | default "")) -}}
{{- $sname := trim (toString ($subnet.name | default "")) -}}
{{- if and (ne $sid "") (ne $sname "") -}}
{{- fail (printf "capos.subnets[%d]: укажите только id или name, не оба сразу" $i) -}}
{{- end -}}
{{- if and (eq $sid "") (eq $sname "") -}}
{{- fail (printf "capos.subnets[%d]: нужен id или name" $i) -}}
{{- end }}
{{- if ne $sid "" }}
- id: {{ $sid | quote }}
{{- else }}
- filter:
    name: {{ $sname | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- else -}}
managedSubnets:
- cidr: {{ required "capos.managedSubnetCIDR обязателен, если capos.network не задан" .Values.capos.managedSubnetCIDR | quote }}
{{- end }}
{{- end }}

{{/*
Validate that default capos values are included in allowed lists (if configured).
*/}}
{{- define "capos-cluster.validateAllowedDefaults" -}}
{{- $allowedFlavors := .Values.capos.allowedFlavors | default (list) -}}
{{- if and (gt (len $allowedFlavors) 0) .Values.capos.flavor (not (has .Values.capos.flavor $allowedFlavors)) -}}
{{- fail (printf "capos.flavor %q must be included in capos.allowedFlavors: [%s]" .Values.capos.flavor (join ", " $allowedFlavors)) -}}
{{- end -}}
{{- $allowedVolumeTypes := .Values.capos.allowedVolumeTypes | default (list) -}}
{{- $defaultVolumeType := .Values.capos.rootVolume.type -}}
{{- if and (gt (len $allowedVolumeTypes) 0) $defaultVolumeType (not (has $defaultVolumeType $allowedVolumeTypes)) -}}
{{- fail (printf "capos.rootVolume.type %q must be included in capos.allowedVolumeTypes: [%s]" $defaultVolumeType (join ", " $allowedVolumeTypes)) -}}
{{- end -}}
{{- end }}

{{/*
Annotations for OpenStack provider secret (used by Shturval backend).
*/}}
{{- define "capos-cluster.providerAnnotations" -}}
shturval.tech/alloweditcsi: {{ .Values.capos.allowEditCSI | quote }}
shturval.tech/availability-zones: {{ include "capos-cluster.availabilityZones" . | quote }}
shturval.tech/allowed-flavors: {{ include "capos-cluster.allowedFlavors" . | quote }}
shturval.tech/allowed-volume-types: {{ include "capos-cluster.allowedVolumeTypes" . | quote }}
shturval.tech/cloud-name: {{ .Values.capos.cloudName | quote }}
shturval.tech/disable-port-security: {{ .Values.capos.disablePortSecurity | quote }}
shturval.tech/external-network-id: {{ .Values.capos.externalNetworkID | quote }}
shturval.tech/managed-security-groups: {{ .Values.capos.managedSecurityGroups.allowAllInClusterTraffic | toString | quote }}
shturval.tech/node-cidr: {{ .Values.capos.managedSubnetCIDR | quote }}
shturval.tech/node-subnet-dns: {{ join "," .Values.capos.nodeSubnetDNS | quote }}
shturval.tech/provider-subtype: {{ .Values.capos.providerSubtype | quote }}
shturval.tech/root-volume-availability-zone: {{ .Values.capos.rootVolumeAvailabilityZone | quote }}
shturval.tech/ssh-key-name: {{ .Values.capos.sshKeyName | quote }}
shturval.tech/template-net-interface: {{ .Values.capos.templateNetInterface | quote }}
{{- range $kubeVersion, $imageName := .Values.capos.kubeTemplates }}
template.shturval.tech/{{ $kubeVersion }}: {{ $imageName | quote }}
{{- end }}
{{- end }}

{{/*
True if any workerNodes group has autoscaling.enabled.
*/}}
{{- define "capos-cluster.autoscalingEnabled" -}}
{{- $enabled := false -}}
{{- range $k, $v := .Values.workerNodes -}}
{{- if and $v.autoscaling $v.autoscaling.enabled -}}
{{- $enabled = true -}}
{{- end -}}
{{- end -}}
{{- $enabled -}}
{{- end -}}

{{/*
Resolve scale params for a worker MachineDeployment group.
Input: dict "root" $ "name" <groupKey> "group" <groupValues>
Output (YAML): enabled, minSize, maxMachines (if enabled), replicas

При autoscaling.enabled чарт не выставляет MachineDeployment.spec.replicas
(см. machinedeployment.yaml) — иначе helm template / helm-diff всегда
показывают drift относительно живого значения, которым владеет cluster-autoscaler.
replicas из values при этом остаётся min-size (пол автоскейлера);
фактический размер группы догоняет autoscaler (--enforce-node-group-min-size).
*/}}
{{- define "capos-cluster.workerGroupScale" -}}
{{- $name := .name -}}
{{- $group := .group -}}
{{- $autoscaling := $group.autoscaling | default dict -}}
{{- $enabled := $autoscaling.enabled | default false -}}
{{- $minSize := $group.replicas -}}
{{- $replicas := $group.replicas -}}
{{- if $enabled -}}
{{- $_ := required (printf "workerNodes.%s.replicas is required when autoscaling.enabled" $name) $group.replicas -}}
{{- $_ := required (printf "workerNodes.%s.autoscaling.maxMachines is required when autoscaling.enabled" $name) $autoscaling.maxMachines -}}
{{- if gt (int $minSize) (int $autoscaling.maxMachines) -}}
{{- fail (printf "workerNodes.%s.replicas (%v) must be <= autoscaling.maxMachines (%v)" $name $minSize $autoscaling.maxMachines) -}}
{{- end -}}
{{- end -}}
enabled: {{ $enabled }}
minSize: {{ $minSize }}
{{- if $enabled }}
maxMachines: {{ $autoscaling.maxMachines }}
{{- end }}
replicas: {{ $replicas }}
{{- end -}}

{{/*
cluster-autoscaler image: <systemregistry>/autoscaling/cluster-autoscaler:v<kubeVersion>
Override via images.clusterAutoscaler when needed.
*/}}
{{- define "capos-cluster.clusterAutoscalerImage" -}}
{{- if and .Values.images .Values.images.clusterAutoscaler -}}
{{- .Values.images.clusterAutoscaler -}}
{{- else -}}
{{- printf "%s/autoscaling/cluster-autoscaler:v%s" .Values.systemregistry .Values.kubeVersion -}}
{{- end -}}
{{- end -}}

{{/*
pause image for NCI (images.pause, fallback nodeInit.pauseImage)
*/}}
{{- define "capos-cluster.pauseImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.pause -}}
{{- $images.pause -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- required "images.pause (or nodeInit.pauseImage) is required" $ni.pauseImage -}}
{{- end -}}
{{- end -}}

{{/*
Filename for a kubeadm patch in kubeadmPatches.directory.
patch.filename, otherwise kubeapi → kube-apiserver.yaml, otherwise <name>.yaml.
*/}}
{{- define "capos-cluster.kubeadmPatchFilename" -}}
{{- $name := .name -}}
{{- $patch := .patch | default dict -}}
{{- if $patch.filename -}}
{{- $patch.filename -}}
{{- else if eq $name "kubeapi" -}}
kube-apiserver.yaml
{{- else -}}
{{- printf "%s.yaml" $name -}}
{{- end -}}
{{- end -}}

{{/*
Node role label suffix for a worker group.
*/}}
{{- define "capos-cluster.nodeRole" -}}
{{- if eq . "default" -}}workers{{- else -}}{{ . }}{{- end -}}
{{- end -}}
