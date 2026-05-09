ARG GRAFANA_VERSION=12.3.0

FROM grafana/grafana:${GRAFANA_VERSION}

# Plugin zur Build-Zeit installieren, nicht zur Laufzeit
RUN grafana cli \
    --pluginsDir /var/lib/grafana/plugins \
    plugins install grafana-clickhouse-datasource

ENV GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=""