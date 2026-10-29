# capos-cluster

Helm-чарт для развёртывания Kubernetes-кластера через **Cluster API** с
инфраструктурным провайдером **CAPOS (Cluster API Provider OpenStack)** и
Shturval `ClusterConfig`. По смыслу — аналог `capvs-cluster` / `capov-cluster` /
`capsm-cluster`, но VM поднимаются в OpenStack.

Чарт создаёт:

- `Namespace` под кластер (имя = `Release.Name`)
- `OpenStackCluster` + `Cluster` (Cluster API)
- `KubeadmControlPlane` + `OpenStackMachineTemplate` для control-plane
- По одному `MachineDeployment` + `KubeadmConfigTemplate` +
  `OpenStackMachineTemplate` на каждую worker-группу из `values.yaml`
- `MachineHealthCheck` (опционально, на control-plane и/или worker-группы)
- Shturval-специфику: `ClusterConfig`, secret с базовой конфигурацией,
  secret для encryption-at-rest, внешние etcd-секреты (если используется)
- Secret c provider-конфигурацией в `capos-system` (опционально, для backend)
- при `workerNodes.<group>.autoscaling.enabled` — Deployment
  `{release}-autoscaler` (Cluster API cluster-autoscaler) + аннотации min/max
  на соответствующем `MachineDeployment`
- опционально (сабчарты): VMAlert/VMRule и Grafana datasource в
  management-кластере (`capos-cluster-vm` / `capos-cluster-grafana`)

> **API endpoint (`clusterAPI`):**
> для CAPOS обычно используется `apiServerLoadBalancer` в OpenStack.
> Если `clusterAPI` пустой, endpoint назначается провайдером автоматически после
> создания LB. Если хотите зарезервировать Floating IP заранее — укажите
> `clusterAPI` вручную.

## Предварительные требования

1. Управляющий кластер с установленными операторами:
   - `cluster-api` core;
   - `cluster-api-provider-openstack` (CAPOS), CRD
     `infrastructure.cluster.x-k8s.io` (чарт использует `v1beta1` для
     инфраструктурных ресурсов);
2. В OpenStack:
   - рабочий `clouds.yaml` (auth URL, project, user, region);
   - внешний network ID для Floating IP (`capos.externalNetworkID`);
   - образы ВМ под целевые версии Kubernetes (см. `capos.kubeTemplates`);
   - flavour'ы и volume type'ы, которые планируете использовать;
   - (опционально) AZ для control-plane/worker.
3. При использовании внешнего etcd — сертификаты лежат в `conf/ext_etcd-*`.

### Чувствительные данные и значения по умолчанию

В `values.yaml` заданы плейсхолдеры (`XXXXXXXX` для лицензии, тестовые/примерные
данные в `capos.cloudsYaml`, примеры FQDN/IP). Реальные значения передавайте при
установке:

- `helm upgrade --install ... -f values-local.yaml` (локальный файл не коммитить);
- или `--set licensetoken=...`, `--set capos.externalNetworkID=...` и т.д.

## Быстрый старт

```bash
helm upgrade --install mycluster . \
  --set licensetoken=XXXXXXXX \
  --set systemregistry=myregistry.domain.tld \
  --set kubeVersion=1.35.1 \
  --set capos.cloudName=openstack \
  --set capos.externalNetworkID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  --set capos.flavor=STD2-4-8 \
  --set capos.templateNetInterface=eth0 \
  --set ingress="app.cluster.example.com" \
  --set authMgmtIngress="shturval.app.mgmt.example.com" \
  --set logsMgmtIngress="logs.app.mgmt.example.com" \
  --set metricsMgmtIngress="vminsert.app.mgmt.example.com"
```

Если нужно заранее зафиксировать endpoint kube-apiserver:

```bash
helm upgrade --install mycluster . \
  -f values-local.yaml \
  --set clusterAPI=10.10.10.50
```

## Ключевые секции `values.yaml`

### Релиз 2.14

| Ключ | Назначение |
|------|-----------|
| `shturvalReleaseVersion` | `2.14.0` |
| `kubeVersion` | `1.35.1` |
| `images.pause` | переопределение образа pause. Иначе берётся из `conf/releases/<shturvalReleaseVersion>.yaml` |
| `images.clusterAutoscaler` | полный образ CA. Иначе тег из профиля релиза (`2.15.0` — `v1.36.1-325745`) и реестр `systemregistry` |
| `services.enabledservices` / `disablesservices` | минимальный набор сервисов 2.14 |

### `capos` — глобальные настройки OpenStack

| Ключ | Назначение |
|------|-----------|
| `cloudName` | Имя cloud в `clouds.yaml` |
| `identitySecretName` | Имя Secret с `clouds.yaml`. Пусто => `Release.Name` |
| `cloudsYaml`, `cacert` | Конфигурация и CA для OpenStack API |
| `externalNetworkID` | ID внешней сети для Floating IP (**обязательно**) |
| `network.id` / `network.name` | Уже существующая сеть узлов. Задан один из них — CAPO не создаёт сеть, подсеть и роутер; `managedSubnetCIDR` игнорируется. Оба сразу задавать нельзя |
| `subnets` | Подсети этой сети (`id` или `name` у каждой). Пусто — все подсети сети, но не больше двух |
| `managedSubnetCIDR` | CIDR подсети, которую создаёт провайдер, если `network` пустой |
| `managedSecurityGroups.allowAllInClusterTraffic` | Политика SG внутри кластера |
| `apiServerLoadBalancer.enabled` | Включение LB для kube-apiserver |
| `controlPlaneAZ` | AZ для control-plane (строка или список). Передаётся в `OpenStackCluster.controlPlaneAvailabilityZones`; если пусто — берётся из `availabilityZones` |
| `defaultWorkerAZ` | AZ по умолчанию для воркеров (строка или список, используется первый элемент). Если не задан — `failureDomain` не ставится |
| `availabilityZones` | Список доступных AZ в облаке: fallback для `controlPlaneAvailabilityZones` и аннотация для backend UI. **Не влияет** на `failureDomain` воркеров |
| `rootVolumeAvailabilityZone` | Явная AZ для root-тома, если она отличается от compute-AZ узла |
| `flavor`, `image`, `sshKeyName` | Дефолтные параметры инстансов |
| `rootVolume` | Размер/тип root-тома по умолчанию |
| `templateNetInterface` | Имя интерфейса в гостевой ОС для cloud-init |
| `allowEditCSI`, `providerSubtype`, `disablePortSecurity` | Аннотации/флаги для backend/провайдера |
| `enableCSI` | `true` — `shturval-capos-csi` и Secret `<identity>-csi` (клон `clouds.yaml`) |
| `nodeSubnetDNS` | DNS-серверы для managed subnet |
| `allowedFlavors`, `allowedVolumeTypes` | Ограничения для backend UI |
| `kubeTemplates` | Маппинг `v<k8s-version> -> image` |
| `createProviderConfig` | Создавать provider secret в `capos-system` |

### Per-group переопределения

`master.*` и `workerNodes.<group>.*` могут переопределить часть параметров
`capos.*`:

```yaml
master:
  replicas: 3
  flavor: "STD2-8-16"
  image: "shturval-2.14.0"
  rootVolume:
    sizeGiB: 80
    type: "ceph-ssd"

workerNodes:
  workers:
    replicas: 3
    availabilityZone: "MS1"
    rootVolume:
      sizeGiB: 60
    labels:
      - "node.longhorn.io/create-default-disk=true"

  infra:
    replicas: 2
    taints:
      - key: mytaint/infra
        effect: NoSchedule
```

### Сеть и балансировщики

Сеть узлов — одна из двух:

- пустые `capos.network.id` и `capos.network.name` — CAPO создаёт сеть, подсеть
  (`capos.managedSubnetCIDR`) и роутер;
- задан `capos.network.id` или `capos.network.name` — узлы садятся в эту сеть.
  `managedSubnets` в `OpenStackCluster` не пишется, свою сеть контроллер не
  создаёт и при удалении кластера не удаляет. Подсеть и шлюз должны уже быть.
  `capos.subnets` сужает выбор: пустой список берёт все подсети сети (CAPO
  разрешает не больше двух — IPv4 и IPv6).

```yaml
capos:
  network:
    id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  subnets:
    - name: "existing-node-subnet"
```

`capos.externalNetworkID` в обоих случаях — внешняя сеть Floating IP, не сеть узлов.

- `clusterAPI`:
  - пусто => endpoint для API появится после создания OpenStack LB;
  - задано => фиксируется в `Cluster` / `OpenStackCluster` / certSANs.
- `ingressVip`, `useExternalIngressLB`:
  - `useExternalIngressLB: true` => используется внешний ingress LB;
  - `useExternalIngressLB: false` => в `ClusterConfig` включается `setupVIP`.

### Зоны доступности (Availability Zones)

#### Принцип разделения

| Поле | Назначение | Используется в |
|------|-----------|----------------|
| `capos.availabilityZones` | Список всех AZ, доступных в этом облаке | `OpenStackCluster.controlPlaneAvailabilityZones` (fallback), аннотация для backend UI |
| `capos.controlPlaneAZ` | Явный список AZ для мастеров | `OpenStackCluster.controlPlaneAvailabilityZones` (приоритет) |
| `capos.defaultWorkerAZ` | Явная AZ по умолчанию для всех воркеров | `MachineDeployment.failureDomain` (если группа не переопределяет) |
| `workerNodes.<group>.availabilityZone` | AZ конкретной воркер-группы | `MachineDeployment.failureDomain` (приоритет над `defaultWorkerAZ`) |
| `capos.rootVolumeAvailabilityZone` | AZ root-тома, если она **отличается** от compute-AZ | `OpenStackMachineTemplate.rootVolume.availabilityZone` (`from: Name`) |

#### Цепочки fallback

**Control plane** (`OpenStackCluster.controlPlaneAvailabilityZones` — список):
```
capos.controlPlaneAZ → capos.availabilityZones → поле не рендерится
```
CAPOS распределяет мастера по всем указанным AZ автоматически.

**Воркеры** (`MachineDeployment.failureDomain` — одна строка на группу):
```
workerNodes.<group>.availabilityZone → capos.defaultWorkerAZ[0] → поле не рендерится
```
`capos.availabilityZones` **не используется** как fallback для воркеров — он описывает облако,
а не указывает, куда размещать машины. Если нужны воркеры в разных AZ — создайте отдельные
группы с явным `availabilityZone`.

**Root-том** (`OpenStackMachineTemplate.rootVolume.availabilityZone`):
```
явный rootVolume.availabilityZone → capos.rootVolumeAvailabilityZone → from:Machine (если compute-AZ задан) → поле не рендерится
```
`from: Machine` означает, что том создаётся в той же AZ, что и сама машина (использует
`failureDomain` машины). Это поведение по умолчанию при наличии compute-AZ.

#### Примеры

**Один регион — одна AZ для всего кластера:**
```yaml
capos:
  controlPlaneAZ: "MS1"
  defaultWorkerAZ: "MS1"
```

**Мастера в трёх AZ, воркеры в двух (в разных группах):**
```yaml
capos:
  controlPlaneAZ:
    - "MS1"
    - "GZ1"
    - "ME1"

workerNodes:
  workers:
    replicas: 3
    availabilityZone: "MS1"
  default-gz:
    replicas: 3
    availabilityZone: "GZ1"
```

**Облако без AZ (не указываем ничего):**
```yaml
capos:
  availabilityZones: []   # или вообще не задавать
  controlPlaneAZ: []
  defaultWorkerAZ: []
```
В этом случае ни `controlPlaneAvailabilityZones`, ни `failureDomain` не рендерятся.

### Внешний etcd

```yaml
etcd:
  external:
    endpoints:
      - "https://10.0.0.1:2379"
    caCrt: "conf/ext_etcd-ca.crt"
    apiCrt: "conf/ext_etcd-client.crt"
    apiKey: "conf/ext_etcd-client.key"
```

При `etcd.external` чарт создаёт secrets:
- `<release>-etcd`
- `<release>-apiserver-etcd-client`

## API-версии

- `infrastructure.cluster.x-k8s.io/v1beta1` — `OpenStackCluster`,
  `OpenStackMachineTemplate`
- `cluster.x-k8s.io/v1beta2` — `Cluster`, `MachineDeployment`,
  `MachineHealthCheck`
- `controlplane.cluster.x-k8s.io/v1beta2` — `KubeadmControlPlane`
- `bootstrap.cluster.x-k8s.io/v1beta2` — `KubeadmConfigTemplate`
- `cluster.shturval.tech/v1beta1` — `ClusterConfig`

## Типовые сценарии

### Изменить количество реплик worker-группы

```yaml
workerNodes:
  workers:
    replicas: 5
```

Затем выполните `helm upgrade`. CAPOS создаст новые VM в OpenStack.

### Автомасштабирование группы узлов (cluster-autoscaler)

Для группы worker-узлов можно включить автомасштабирование через Cluster API
cluster-autoscaler (как в UI/backend Штурвала и в чартах `capsm-cluster` /
`capvs-cluster` / `capov-cluster`):

```yaml
workerNodes:
  workers:
    replicas: 2 # минимум и стартовое число узлов
    autoscaling:
      enabled: true
      maxMachines: 6
```

Что происходит при `autoscaling.enabled: true`:

- на `MachineDeployment` выставляются аннотации
  `cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size` (= `replicas`) и
  `...-max-size` (= `maxMachines`);
- `spec.replicas` **не рендерится** (им владеет autoscaler) — иначе
  `helm template` / helm-diff показывают вечный drift;
- в namespace кластера создаются ServiceAccount, ClusterRoleBinding на
  `shturval-cluster-autoscaler` и Deployment `{release}-autoscaler`
  с `--enforce-node-group-min-size`.

CAPOS при scale up создаёт новые VM в OpenStack из образа — нужны свободные
ресурсы и квота. На management-кластере должен быть ClusterRole
`shturval-cluster-autoscaler` (ставит платформа).

### Добавить новую worker-группу

```yaml
workerNodes:
  gpu:
    replicas: 2
    flavor: "GPU-8-32"
    image: "shturval-2.14.0-gpu"
    rootVolume:
      sizeGiB: 120
      type: "ceph-ssd"
    labels:
      - "node-role.kubernetes.io/gpu="
    taints:
      - key: node-role.kubernetes.io/gpu
        effect: NoSchedule
```

### Включить MachineHealthCheck для группы

```yaml
workerNodes:
  workers:
    machineHealthCheck:
      enabled: true
      checks:
        nodeStartupTimeoutSeconds: 0
        unhealthyNodeConditions:
          - status: "False"
            timeoutSeconds: 600
            type: Ready
      remediation:
        triggerIf:
          unhealthyLessThanOrEqualTo: 40%
```

### Не появляется `clusterAPI`

Проверьте:

1. `capos.externalNetworkID` корректен и доступна выдача Floating IP.
2. `capos.apiServerLoadBalancer.enabled: true`.
3. В `capos.cloudsYaml` верные `auth_url`, project/user, region и права.
4. Статусы `OpenStackCluster` и событий CAPOS-контроллера в management-кластере.
5. Если `clusterAPI` задаёте вручную — IP должен быть маршрутизируем и свободен.

### Секрет провайдера уже существует в `capos-system`

Если провайдер уже создан через backend UI, отключите создание из чарта:

```yaml
capos:
  createProviderConfig: false
```

### Мониторинг в management-кластере

Сабчарты (те же, что в CAPSM/CAPVS/CAPOV; в values — через alias):

```yaml
capos-cluster-vm:
  enable: true       # VMAlert / VMRule под monitoringId кластера
capos-cluster-grafana:
  enable: true       # datasource в Grafana management-кластера
```

Ресурсы создаются в namespace релиза (имя клиентского кластера).

## Удаление

```bash
helm uninstall mycluster
```

VM и связанные ресурсы удаляются контроллерами Cluster API/CAPOS после удаления
`MachineDeployment` / `KubeadmControlPlane`.

## Обновление чарта с 2.14 на 2.15

Чарт `2.15` ставит новый кластер Штурвала **2.15.0** (Kubernetes 1.36.5).
Уже работающий кластер 2.14 этим чартом обновляется только как Helm-релиз:
машины не пересоздаются и обновление платформы не стартует, если values
по-прежнему описывают 2.14.

1. Сначала обновите менеджмент-кластер до Штурвала 2.15 (CRD `InfrastructureProvider`, CAPI v1beta2). Потом обновляйте чарты клиентских кластеров.
2. Возьмите values, которыми кластер ставился (`helm get values <release> -n <namespace> -o yaml`), а не дефолты нового чарта.
3. Не используйте `--reuse-values` вслепую и не подставляйте голый `--reset-values`: новый чарт по умолчанию содержит `shturvalReleaseVersion: 2.15.0`, `kubeVersion: 1.36.5`, новые теги etcd, pause и kube-vip. Для обновления только чарта оставьте прежние версии.
4. Предпочтительно `helm upgrade --reset-then-reuse-values` вместе с файлом старых values, затем `helm diff upgrade` (если плагин установлен) или `helm template` / `helm upgrade --dry-run`.
5. `shturvalReleaseVersion` меняйте только вместе с `platformUpgrade: true`. Иначе при живом кластере чарт останавливает рендер: смена `spec.releaseVersion` запускает обновление платформы. `helm template` и Argo CD не видят объекты кластера (`lookup` пустой), поэтому проверку нужно сделать до apply.
6. `enabledServices` и `disabledServices` у существующего ClusterConfig чарт не переписывает: webhook запрещает их менять, списки читаются из живого объекта.
7. `InfrastructureProvider` создаётся только если CRD уже есть (`infrastructureProvider.create: auto`) и объект с тем же именем не принадлежит другому релизу. Нативные секреты и аннотации `shturval.tech/*` чарт не удаляет: они нужны менеджмент-кластеру 2.14 и миграции 2.15.
8. Поле `services.disablesservices` — явный список. Значение `all` в ClusterConfig не работает (его понимает только REST API backend и нельзя совместить с `enabledServices`). Некритичный сервис, которого нет ни в одном списке и у которого режим по умолчанию `auto`, будет установлен.

Платформенное обновление клиентского кластера 2.14 → 2.15 делайте отдельно, через shturval-update / `platformUpgrade: true`, а не как побочный эффект `helm upgrade`.
