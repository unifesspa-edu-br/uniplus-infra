# unifesspa-geo-api

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.1](https://img.shields.io/badge/AppVersion-1.0.1-informational?style=flat-square)

API .NET 10 de localidades/CEP/georreferenciamento institucional da UNIFESSPA
(módulo Geo, extraído para repo próprio unifesspa-geo-api). PostGIS via
ConnectionStrings__GeoDb, cache Redis, cifragem AES-GCM (local ou Vault
Transit). Health: /health (readiness agregado), /health/live (liveness),
/health/ready (dependências).

**Homepage:** <https://github.com/unifesspa-edu-br/uniplus-infra>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| CTIC UNIFESSPA | <jeferson.ferreira@unifesspa.edu.br> |  |

## Source Code

* <https://github.com/unifesspa-edu-br/uniplus-infra>
* <https://github.com/unifesspa-edu-br/unifesspa-geo-api>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| commonLabels."app.kubernetes.io/component" | string | `"api"` |  |
| commonLabels."app.kubernetes.io/part-of" | string | `"uniplus"` |  |
| unifesspaGeoApi.aspnet.environment | string | `"Production"` |  |
| unifesspaGeoApi.aspnet.urls | string | `"http://+:8080"` |  |
| unifesspaGeoApi.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| unifesspaGeoApi.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| unifesspaGeoApi.containerSecurityContext.readOnlyRootFilesystem | bool | `false` |  |
| unifesspaGeoApi.containerSecurityContext.runAsNonRoot | bool | `true` |  |
| unifesspaGeoApi.containerSecurityContext.runAsUser | int | `999` |  |
| unifesspaGeoApi.cors.allowedOrigins | list | `[]` |  |
| unifesspaGeoApi.customCA.certPEM | string | `""` |  |
| unifesspaGeoApi.customCA.enabled | bool | `false` |  |
| unifesspaGeoApi.customCA.existingSecretKey | string | `"tls.crt"` |  |
| unifesspaGeoApi.customCA.existingSecretName | string | `""` |  |
| unifesspaGeoApi.database.connectionStringName | string | `"GeoDb"` |  |
| unifesspaGeoApi.database.host | string | `""` |  |
| unifesspaGeoApi.database.name | string | `"uniplus_geo"` |  |
| unifesspaGeoApi.database.port | int | `5432` |  |
| unifesspaGeoApi.database.username | string | `"uniplus_geo_app"` |  |
| unifesspaGeoApi.enabled | bool | `false` |  |
| unifesspaGeoApi.encryption.kubernetesRole | string | `""` |  |
| unifesspaGeoApi.encryption.provider | string | `"local"` |  |
| unifesspaGeoApi.encryption.vaultAddress | string | `""` |  |
| unifesspaGeoApi.encryption.vaultTransitMount | string | `"transit"` |  |
| unifesspaGeoApi.externalSecrets.enabled | bool | `true` |  |
| unifesspaGeoApi.externalSecrets.encryptionLocalKey.localKeyKey | string | `"local_key"` |  |
| unifesspaGeoApi.externalSecrets.encryptionLocalKey.vaultPath | string | `"secret/standalone/geo/encryption"` |  |
| unifesspaGeoApi.externalSecrets.postgresApp.passwordKey | string | `"password"` |  |
| unifesspaGeoApi.externalSecrets.postgresApp.vaultPath | string | `"secret/standalone/postgres/geo"` |  |
| unifesspaGeoApi.externalSecrets.redisDefault.passwordKey | string | `"password"` |  |
| unifesspaGeoApi.externalSecrets.redisDefault.vaultPath | string | `"secret/standalone/redis/default"` |  |
| unifesspaGeoApi.externalSecrets.refreshInterval | string | `"1h"` |  |
| unifesspaGeoApi.externalSecrets.secretStoreRef.kind | string | `"ClusterSecretStore"` |  |
| unifesspaGeoApi.externalSecrets.secretStoreRef.name | string | `"vault-default"` |  |
| unifesspaGeoApi.extraEnv | list | `[]` |  |
| unifesspaGeoApi.image.pullPolicy | string | `"IfNotPresent"` |  |
| unifesspaGeoApi.image.registry | string | `"ghcr.io"` |  |
| unifesspaGeoApi.image.repository | string | `"unifesspa-edu-br/unifesspa-geo-api"` |  |
| unifesspaGeoApi.image.tag | string | `"v1.0.1"` |  |
| unifesspaGeoApi.imagePullSecrets | list | `[]` |  |
| unifesspaGeoApi.ingress.enabled | bool | `false` |  |
| unifesspaGeoApi.ingress.entryPoint | string | `"websecure"` |  |
| unifesspaGeoApi.ingress.host | string | `""` |  |
| unifesspaGeoApi.ingress.tls.certManager.clusterIssuer | string | `""` |  |
| unifesspaGeoApi.ingress.tls.certManager.enabled | bool | `false` |  |
| unifesspaGeoApi.ingress.tls.enabled | bool | `true` |  |
| unifesspaGeoApi.ingress.tls.secretName | string | `""` |  |
| unifesspaGeoApi.livenessProbe.periodSeconds | int | `10` |  |
| unifesspaGeoApi.metrics.enabled | bool | `false` |  |
| unifesspaGeoApi.networkPolicy.dataHostCIDR | string | `""` |  |
| unifesspaGeoApi.networkPolicy.enabled | bool | `true` |  |
| unifesspaGeoApi.networkPolicy.keycloakNamespace | string | `"uniplus"` |  |
| unifesspaGeoApi.networkPolicy.keycloakPort | int | `8080` |  |
| unifesspaGeoApi.networkPolicy.keycloakService | string | `"keycloak-replica"` |  |
| unifesspaGeoApi.networkPolicy.monitoringNamespace | string | `"observability-prometheus"` |  |
| unifesspaGeoApi.networkPolicy.oidcIssuerCIDR | string | `""` |  |
| unifesspaGeoApi.networkPolicy.oidcIssuerPort | int | `443` |  |
| unifesspaGeoApi.networkPolicy.otelCollectorNamespace | string | `"observability-otelcol"` |  |
| unifesspaGeoApi.networkPolicy.traefikNamespace | string | `"traefik"` |  |
| unifesspaGeoApi.networkPolicy.vaultNamespace | string | `"vault"` |  |
| unifesspaGeoApi.networkPolicy.vaultPort | int | `8200` |  |
| unifesspaGeoApi.oidc.audience | string | `""` |  |
| unifesspaGeoApi.oidc.enabled | bool | `true` |  |
| unifesspaGeoApi.oidc.issuerUri | string | `""` |  |
| unifesspaGeoApi.oidc.validateAudience | bool | `false` |  |
| unifesspaGeoApi.otel.enabled | bool | `false` |  |
| unifesspaGeoApi.otel.exporter.endpoint | string | `""` |  |
| unifesspaGeoApi.otel.exporter.protocol | string | `"grpc"` |  |
| unifesspaGeoApi.otel.resource.serviceName | string | `""` |  |
| unifesspaGeoApi.podSecurityContext.fsGroup | int | `999` |  |
| unifesspaGeoApi.readinessProbe.periodSeconds | int | `5` |  |
| unifesspaGeoApi.redis.host | string | `""` |  |
| unifesspaGeoApi.redis.port | int | `6379` |  |
| unifesspaGeoApi.redis.username | string | `"default"` |  |
| unifesspaGeoApi.replicas | int | `1` |  |
| unifesspaGeoApi.resources.limits.cpu | string | `"1000m"` |  |
| unifesspaGeoApi.resources.limits.memory | string | `"512Mi"` |  |
| unifesspaGeoApi.resources.requests.cpu | string | `"100m"` |  |
| unifesspaGeoApi.resources.requests.memory | string | `"256Mi"` |  |
| unifesspaGeoApi.serviceAccount.create | bool | `true` |  |
| unifesspaGeoApi.serviceAccount.name | string | `""` |  |
| unifesspaGeoApi.serviceMonitor.enabled | bool | `false` |  |
| unifesspaGeoApi.serviceMonitor.interval | string | `"30s"` |  |
| unifesspaGeoApi.startupProbe.failureThreshold | int | `60` |  |
| unifesspaGeoApi.startupProbe.periodSeconds | int | `5` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
