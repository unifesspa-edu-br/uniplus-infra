akhq:
  # Conexões a clusters Kafka. Em standalone só temos 1; o `bootstrap-servers`
  # vem do values; SCRAM credentials são injetadas via env (envFrom do Secret
  # sintetizado pelo ESO `kafka-admin`). CA cert PEM montado em /etc/akhq/certs/ca.crt
  # via projected volume — também sintetizado pelo ESO.
  connections:
    {{ .Values.kafkaUi.kafka.clusterName }}:
      properties:
        bootstrap.servers: "{{ .Values.kafkaUi.kafka.bootstrapServers }}"
        security.protocol: {{ .Values.kafkaUi.kafka.securityProtocol }}
        sasl.mechanism: {{ .Values.kafkaUi.kafka.saslMechanism }}
        # JAAS config interpolado de env (KAFKA_USERNAME + KAFKA_PASSWORD
        # vêm do envFrom do Secret kafka-admin sintetizado pelo ESO).
        sasl.jaas.config: 'org.apache.kafka.common.security.scram.ScramLoginModule required username="${KAFKA_USERNAME}" password="${KAFKA_PASSWORD}";'
        ssl.truststore.type: PEM
        ssl.truststore.location: /etc/akhq/certs/ca.crt
        # Self-signed cert do broker tem SAN cobrindo IP + DNS, mas
        # disabilitar hostname verification mantém o pattern do
        # admin.properties do data-host (§13).
        ssl.endpoint.identification.algorithm: ""

  # Segurança: OIDC via Keycloak realm `uniplus`.
  security:
    default-group: no-roles
    groups:
      no-roles:
        roles: []
        attributes: { description: "Sem permissão" }
      kafka-admins:
        roles:
          - topic/read
          - topic/insert
          - topic/delete
          - topic/config/update
          - group/read
          - group/delete
          - group/offsets/update
          - schema/read
          - schema/insert
          - schema/delete
          - schema/version/delete
          - acl/read
          - acl/insert
          - acl/delete
          - node/read
          - node/config/update
        attributes: { description: "Administradores do Kafka" }
      kafka-readonly:
        roles:
          - topic/read
          - group/read
          - schema/read
          - acl/read
          - node/read
        attributes: { description: "Acesso de leitura ao Kafka" }
{{- if .Values.kafkaUi.oidc.enabled }}
    oidc:
      enabled: true
      providers:
        {{ .Values.kafkaUi.oidc.providerName }}:
          label: "Login Uni+"
          # Mapping do claim `groups` (do Keycloak) para grupos AKHQ.
          # O token JWT do Keycloak deve ter um mapper `groups` configurado
          # para incluir o membership do usuário.
          groups-field: {{ .Values.kafkaUi.oidc.groupsClaim }}
          username-field: preferred_username
          # AKHQ OIDC mapping: `name:` é a key da role AKHQ definida acima
          # em `akhq.security.groups` (NÃO a claim do IdP); `groups:` lista
          # os valores que o IdP devolve no claim `groups-field` que devem
          # ser mapeados a essa role. Usar `role:` é syntax incorreta — AKHQ
          # ignora silenciosamente e o user cai em default-group=no-roles.
          groups:
            - name: kafka-admins
              groups:
                - "{{ .Values.kafkaUi.oidc.groups.kafkaAdminsClaim }}"
            - name: kafka-readonly
              groups:
                - "{{ .Values.kafkaUi.oidc.groups.kafkaReadOnlyClaim }}"
{{- end }}

# Micronaut OIDC (consumido pelo AKHQ). issuer + client_id no values;
# client_secret via env OIDC_CLIENT_SECRET (envFrom do Secret kafka-ui-oidc-client).
{{- if .Values.kafkaUi.oidc.enabled }}
micronaut:
  security:
    enabled: true
    authentication: idtoken
    oauth2:
      enabled: true
      clients:
        {{ .Values.kafkaUi.oidc.providerName }}:
          client-id: {{ .Values.kafkaUi.oidc.clientId }}
          client-secret: ${OIDC_CLIENT_SECRET}
          openid:
            issuer: "{{ .Values.kafkaUi.oidc.issuerUri }}"
    endpoints:
      logout:
        get-allowed: true
{{- end }}

{{- if .Values.kafkaUi.metrics.enabled }}
endpoints:
  prometheus:
    sensitive: false
{{- end }}
