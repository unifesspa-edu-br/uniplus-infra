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
          # AKHQ OIDC mapping (sintaxe correta — verificada via doc oficial
          # https://akhq.io/docs/configuration/authentifications/oidc.html
          # após bug runtime descoberto em login real):
          #   - `name:` é o VALOR do claim do IdP (ex: "/admins/kafka")
          #   - `groups:` lista os AKHQ role groups (definidos em
          #     akhq.security.groups acima) que o user assume
          # Inverso: usar `name: kafka-admins` + `groups: [/admins/kafka]`
          # passa silenciosamente em start (sem erro de schema) mas mapa
          # nunca match — user fica com roles=[isAuthenticated()] only,
          # cookie JWT tem groups vazio "{}", "página inicial" não carrega
          # tópicos. Esse foi o bug que ficou pendente em #142 → #149.
          groups:
            - name: "{{ .Values.kafkaUi.oidc.groups.kafkaAdminsClaim }}"
              groups:
                - kafka-admins
            - name: "{{ .Values.kafkaUi.oidc.groups.kafkaReadOnlyClaim }}"
              groups:
                - kafka-readonly
{{- end }}

# Micronaut OIDC (consumido pelo AKHQ). issuer + client_id no values;
# client_secret via env OIDC_CLIENT_SECRET (envFrom do Secret kafka-ui-oidc-client).
#
# authentication: cookie — Micronaut gera sua própria JWT de sessão
# (assinada com HS256 + MICRONAUT_SECURITY_TOKEN_JWT_SIGNATURES_SECRET_GENERATOR_SECRET
# do ESO) ao invés de reusar o id_token do Keycloak como cookie. Necessário
# porque o AKHQ OidcAuthenticationMapper sobrescreve o attributes map do
# Authentication, perdendo o `openid-token` que `idtoken` mode espera —
# resultando em `OauthErrorResponseException` no IdTokenLoginHandler:103
# após login OIDC bem-sucedido. Com cookie mode, AKHQ pode mapear claims
# (groups, username) sem que Micronaut dependa do id_token preservado.
#
# Bloco token.jwt.signatures.secret.generator: declaração explícita do secret
# generator necessária para Micronaut Security USAR a env var MICRONAUT_SECURITY_*
# como secret estável (HS256). Sem esse bloco, Micronaut gera random secret
# em-memória por request — cookie da sessão não valida em requests seguintes,
# causando loop redirect /oauth/login → callback → login. Documentação oficial
# Micronaut Security exige esse bloco mesmo quando env var "auto-binda".
#
# Micronaut faz auto-discovery do JWKS endpoint via .well-known/openid-configuration
# do issuer — config explícita de jwks.* causa NonUniqueBeanException na imagem
# AKHQ 0.27.0. Pattern: deixar Micronaut descobrir automaticamente.
{{- if .Values.kafkaUi.oidc.enabled }}
micronaut:
  security:
    enabled: true
    authentication: cookie
    token:
      jwt:
        signatures:
          secret:
            generator:
              secret: ${MICRONAUT_SECURITY_TOKEN_JWT_SIGNATURES_SECRET_GENERATOR_SECRET}
              base64: false
              jws-algorithm: HS256
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
