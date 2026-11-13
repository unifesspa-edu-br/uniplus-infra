akhq:
  # Conexões a clusters Kafka. Só há um; o `bootstrap-servers` vem do values. A
  # credencial SCRAM é a própria da interface (`kafkaCredentials`, só leitura no
  # broker), injetada por env do Secret sintetizado pelo ESO. O CA PEM do broker
  # é montado em /etc/akhq/certs/ca.crt, do mesmo Secret.
  connections:
    {{ .Values.kafkaUi.kafka.clusterName }}:
      properties:
        bootstrap.servers: "{{ .Values.kafkaUi.kafka.bootstrapServers }}"
        security.protocol: {{ .Values.kafkaUi.kafka.securityProtocol }}
        sasl.mechanism: {{ .Values.kafkaUi.kafka.saslMechanism }}
        # JAAS config interpolado de env (KAFKA_USERNAME + KAFKA_PASSWORD
        # vêm do Secret kafka-credentials sintetizado pelo ESO).
        sasl.jaas.config: 'org.apache.kafka.common.security.scram.ScramLoginModule required username="${KAFKA_USERNAME}" password="${KAFKA_PASSWORD}";'
        ssl.truststore.type: PEM
        ssl.truststore.location: /etc/akhq/certs/ca.crt
        # Vazio desliga a verificação do nome do broker (certificado autoassinado
        # do data-host, §13); `https` valida o nome contra o certificado.
        ssl.endpoint.identification.algorithm: {{ .Values.kafkaUi.kafka.sslEndpointIdentification | quote }}

  # Segurança: OIDC via Keycloak realm `uniplus`.
  #
  # O AKHQ traz os grupos embutidos `admin` (tudo), `reader` (leitura de tudo,
  # inclusive o conteúdo das mensagens) e `no-roles` (nada). O grupo OIDC de
  # administração mapeia direto para `admin`. A leitura de conteúdo não usa o
  # `reader` irrestrito: o grupo `leitor-de-conteudo` abaixo reaproveita o papel
  # `reader` com o padrão que exclui os tópicos de topicosSemLeituraNaInterface.
  # Quem não casa com nenhum grupo mapeado (inclusive `/users/uniplus`) fica no
  # `default-group: no-roles`.
  #
  # Padrões de grupo são regex positivas: o recurso precisa casar com ao menos
  # uma. A exclusão é o lookahead negativo montado em
  # kafkaUi.padraoDeTopicosLegiveis. Só a interface é restringida; o limite
  # firme é a ACL de `Read` negada à credencial no broker.
  #
  # Exige o segredo de assinatura do JWT (ver abaixo): sem ele o AKHQ aplica os
  # grupos só na interface, não na API.
  security:
    default-group: no-roles
    groups:
      leitor-de-conteudo:
        - role: reader
          patterns:
            - '{{ include "kafkaUi.padraoDeTopicosLegiveis" . }}'
{{- if .Values.kafkaUi.oidc.enabled }}
    oidc:
      enabled: true
      providers:
        {{ .Values.kafkaUi.oidc.providerName }}:
          label: "Login Uni+"
          groups-field: {{ .Values.kafkaUi.oidc.groupsClaim }}
          username-field: preferred_username
          # Mapeamento do claim `groups` do Keycloak (o client precisa do mapper
          # `groups` com caminho completo):
          #   - `name:` é o VALOR do claim no IdP (ex.: "/admins/kafka");
          #   - `groups:` lista os grupos do AKHQ que o usuário assume.
          # Inverter (`name:` com o nome do grupo do AKHQ) passa sem erro na
          # partida, mas nunca casa, e o usuário entra sem nenhum papel.
          groups:
            - name: "{{ .Values.kafkaUi.oidc.groups.kafkaAdminsClaim }}"
              groups:
                - admin
            - name: "{{ .Values.kafkaUi.oidc.groups.kafkaDataReadersClaim }}"
              groups:
                - leitor-de-conteudo
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
