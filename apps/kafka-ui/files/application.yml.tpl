{{- $semLeitura := list -}}
{{- range .Values.kafkaUi.topicosSemLeituraNaInterface -}}
{{- $semLeitura = append $semLeitura (regexQuoteMeta .) -}}
{{- end -}}
akhq:
  # Conexão ao Kafka do ambiente. O usuário e a senha SCRAM chegam por env
  # (KAFKA_USERNAME e KAFKA_PASSWORD, do Secret sintetizado pelo ESO a partir de
  # `externalSecrets.kafkaCredencial`). É o usuário próprio do AKHQ, nunca o
  # `admin`: o `admin` é superusuário do broker e passa por cima das ACLs. O CA
  # do broker é montado em /etc/akhq/certs/ca.crt, do mesmo Secret.
  connections:
    {{ .Values.kafkaUi.kafka.clusterName }}:
      properties:
        bootstrap.servers: "{{ .Values.kafkaUi.kafka.bootstrapServers }}"
        security.protocol: {{ .Values.kafkaUi.kafka.securityProtocol }}
        sasl.mechanism: {{ .Values.kafkaUi.kafka.saslMechanism }}
        sasl.jaas.config: 'org.apache.kafka.common.security.scram.ScramLoginModule required username="${KAFKA_USERNAME}" password="${KAFKA_PASSWORD}";'
        ssl.truststore.type: PEM
        ssl.truststore.location: /etc/akhq/certs/ca.crt
        # Vazio desliga a verificação do nome do broker; `https` valida o nome
        # contra o certificado.
        ssl.endpoint.identification.algorithm: {{ .Values.kafkaUi.kafka.sslEndpointIdentification | quote }}

  # Autorização na interface (OIDC do Keycloak).
  #
  # Quem não casa com nenhum grupo cai em `no-roles` (grupo embutido, sem
  # permissão). O grupo embutido `reader` NÃO é usado: ele dá READ em
  # TOPIC_DATA de todos os tópicos, inclusive da trilha de acessos.
  #
  # Papéis próprios (sintaxe do AKHQ 0.25+, `resources` × `actions`), somados
  # aos embutidos:
  #   kafka-ui-metadados — tópicos, partições, offsets, grupos de consumo, nós
  #                        e ACLs, sem conteúdo de mensagem;
  #   kafka-ui-mensagens — conteúdo de mensagens (TOPIC_DATA), ligado ao grupo
  #                        só com o padrão que exclui `topicosSemLeituraNaInterface`.
  #
  # A exclusão aqui é defesa em profundidade: a credencial do AKHQ no broker já
  # tem `Read` negado nesses tópicos (provisionar-kafka-ui.sh), e é isso que
  # também barra o papel `admin`.
  security:
    default-group: no-roles
    roles:
      kafka-ui-metadados:
        - resources: [ "TOPIC", "CONSUMER_GROUP", "NODE", "ACL" ]
          actions: [ "READ" ]
        - resources: [ "TOPIC", "NODE" ]
          actions: [ "READ_CONFIG" ]
      kafka-ui-mensagens:
        - resources: [ "TOPIC_DATA" ]
          actions: [ "READ" ]
    groups:
      kafka-ui-leitores:
        - role: kafka-ui-metadados
          patterns: [ ".*" ]
          clusters: [ ".*" ]
        - role: kafka-ui-mensagens
          # Casa qualquer tópico, menos os listados (nome inteiro).
          patterns: [ '^(?!(?:{{ join "|" $semLeitura }})$).*$' ]
          clusters: [ ".*" ]
{{- if .Values.kafkaUi.oidc.enabled }}
    oidc:
      enabled: true
      providers:
        {{ .Values.kafkaUi.oidc.providerName }}:
          label: "Login Uni+"
          # O token do Keycloak precisa do mapper `groups` com caminho completo.
          groups-field: {{ .Values.kafkaUi.oidc.groupsClaim }}
          username-field: preferred_username
          # `name:` é o VALOR do claim (ex.: "/admins/kafka"); `groups:` são os
          # grupos do AKHQ que a pessoa assume. Invertido, o mapa nunca casa e a
          # pessoa entra sem permissão nenhuma.
          #   /admins/kafka            → admin (embutido; no broker, só leitura)
          #   leitoresDeConteudoClaim  → kafka-ui-leitores (acima)
          groups:
            - name: "{{ .Values.kafkaUi.oidc.groups.kafkaAdminsClaim }}"
              groups:
                - admin
            - name: "{{ .Values.kafkaUi.oidc.groups.leitoresDeConteudoClaim }}"
              groups:
                - kafka-ui-leitores
{{- end }}

# Micronaut OIDC (consumido pelo AKHQ). issuer e client_id no values;
# client_secret via env OIDC_CLIENT_SECRET (Secret <fullname>-oidc-client).
#
# authentication: cookie — o Micronaut gera a própria JWT de sessão, assinada
# com HS256 e o segredo de MICRONAUT_SECURITY_TOKEN_JWT_SIGNATURES_SECRET_GENERATOR_SECRET.
# No modo `idtoken`, o OidcAuthenticationMapper do AKHQ descarta o
# `openid-token` e o login termina em OauthErrorResponseException.
#
# O bloco token.jwt.signatures.secret.generator é obrigatório: sem ele o
# Micronaut gera um segredo aleatório em memória, o cookie não valida na
# requisição seguinte e o login entra em laço. É esse segredo estável que faz o
# AKHQ aplicar os grupos também na API, e não só na interface.
#
# O JWKS vem da descoberta automática do issuer; declarar jwks.* causa
# NonUniqueBeanException no AKHQ 0.27.0.
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
