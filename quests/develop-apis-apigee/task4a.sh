#!/bin/bash -x

cd ~/develop-apis-apigee/rest-backend
source config.sh


#!/bin/bash

# Configurações do Ambiente (Seu Projeto do Qwiklabs)
# O script tenta pegar o ID atual de forma dinâmica se rodado no Cloud Shell
export PROJECT_ID=$GOOGLE_CLOUD_PROJECT
export ENV="eval"
export AUTH="Authorization: Bearer $(gcloud auth print-access-token)"
export SF_NAME="get-address-for-location"

echo "=== Iniciando criação do Shared Flow: $SF_NAME ==="
echo "Projeto Alvo: $PROJECT_ID"

# 1. Criação da Estrutura de Diretórios Padronizada do Apigee
mkdir -p sharedflowbundle/sharedflows
mkdir -p sharedflowbundle/policies

# 2. Criando o Manifesto Principal do Shared Flow Bundle
cat <<EOF > sharedflowbundle/$SF_NAME.xml
<SharedFlowBundle name="$SF_NAME">
    <DisplayName>$SF_NAME</DisplayName>
    <SharedFlows>
        <SharedFlow>default</SharedFlow>
    </SharedFlows>
</SharedFlowBundle>
EOF

# 3. Criando as Políticas (Policies) individuais
# 3.1 Lookup Cache
cat <<EOF > sharedflowbundle/policies/LC-LookupAddress.xml
<LookupCache continueOnError="false" enabled="true" name="LC-LookupAddress">
  <CacheResource>AddressesCache</CacheResource>
  <Scope>Exclusive</Scope>
  <CacheKey>
    <KeyFragment ref="geocoding.latitude"/>
    <KeyFragment ref="geocoding.longitude"/>
  </CacheKey>
  <AssignTo>geocoding.address</AssignTo>
</LookupCache>
EOF

# 3.2 Service Callout
cat <<EOF > sharedflowbundle/policies/SC-GoogleGeocode.xml
<ServiceCallout continueOnError="false" enabled="true" name="SC-GoogleGeocode">
  <Request>
    <Set>
      <QueryParams>
        <QueryParam name="latlng">{geocoding.latitude},{geocoding.longitude}</QueryParam>
        <QueryParam name="key">{geocoding.apikey}</QueryParam>
      </QueryParams>
      <Verb>GET</Verb>
    </Set>
  </Request>
  <Response>calloutResponse</Response>
  <HTTPTargetConnection>
    <URL>https://maps.googleapis.com/maps/api/geocode/json</URL>
  </HTTPTargetConnection>
</ServiceCallout>
EOF

# 3.3 Extract Variables
cat <<EOF > sharedflowbundle/policies/EV-ExtractAddress.xml
<ExtractVariables continueOnError="false" enabled="true" name="EV-ExtractAddress">
  <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
  <JSONPayload>
    <Variable name="address">
      <JSONPath>$.results[0].formatted_address</JSONPath>
    </Variable>
  </JSONPayload>
  <Source clearPayload="false">calloutResponse.content</Source>
  <VariablePrefix>geocoding</VariablePrefix>
</ExtractVariables>
EOF

# 3.4 Populate Cache
cat <<EOF > sharedflowbundle/policies/PC-StoreAddress.xml
<PopulateCache continueOnError="false" enabled="true" name="PC-StoreAddress">
  <CacheResource>AddressesCache</CacheResource>
  <Scope>Exclusive</Scope>
  <Source>geocoding.address</Source>
  <CacheKey>
    <KeyFragment ref="geocoding.latitude"/>
    <KeyFragment ref="geocoding.longitude"/>
  </CacheKey>
  <ExpirySettings>
    <TimeoutInSec>3600</TimeoutInSec>
  </ExpirySettings>
</PopulateCache>
EOF

# 4. Criando o fluxo sequencial padrão (default.xml) com as condicionais de Cache Hit
cat <<EOF > sharedflowbundle/sharedflows/default.xml
<SharedFlow name="default">
  <Step>
    <Name>LC-LookupAddress</Name>
  </Step>
  <Step>
    <Condition>lookupcache.LC-LookupAddress.cachehit == false</Condition>
    <Name>SC-GoogleGeocode</Name>
  </Step>
  <Step>
    <Condition>lookupcache.LC-LookupAddress.cachehit == false</Condition>
    <Name>EV-ExtractAddress</Name>
  </Step>
  <Step>
    <Condition>lookupcache.LC-LookupAddress.cachehit == false</Condition>
    <Name>PC-StoreAddress</Name>
  </Step>
</SharedFlow>
EOF

echo "-> Estrutura local criada com sucesso. Compactando bundle..."

# 5. Compactando em arquivo ZIP para importação do Apigee
rm -f sharedflowbundle.zip
zip -r sharedflowbundle.zip sharedflowbundle/ > /dev/null

echo "-> Enviando pacote do Shared Flow para a API do Apigee..."

# 6. Importando o Shared Flow para a Organização do Apigee (Cria a Revisão 1)
# O endpoint 'sharedflows' recebe o arquivo binário em formato multipart
RESPONSE=$(curl -s -X POST \
  -H "$AUTH" \
  -F "file=@sharedflowbundle.zip" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/sharedflows?name=${SF_NAME}&action=import")

# Extrai o número da revisão criada a partir do JSON de resposta (usualmente revision "1")
REVISION=$(echo "$RESPONSE" | grep -oP '"revision":\s*"\K[^"]+')

if [ -z "$REVISION" ]; then
    echo "Erro ao importar Shared Flow. Resposta da API:"
    echo "$RESPONSE"
    exit 1
fi

echo "-> Shared Flow importado com sucesso como Revisão $REVISION."
echo "-> Iniciando o deploy no ambiente '$ENV'..."

# 7. Executando o Deploy da revisão importada (sem Service Account anexada)
DEPLOY_RESPONSE=$(curl -s -X POST \
  -H "$AUTH" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/environments/${ENV}/sharedflows/${SF_NAME}/revisions/${REVISION}/deployments")

echo "=== Processo Concluído! ==="
echo "Status do Deploy:"
echo "$DEPLOY_RESPONSE" | grep -E "state|revision" || echo "$DEPLOY_RESPONSE"

# Limpeza opcional dos temporários criados localmente
rm -rf sharedflowbundle sharedflowbundle.zip

