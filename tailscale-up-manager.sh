#!/usr/bin/env bash
#
# tailscale-up-manager.sh
# Dieses Skript:
#  1) Liest Docker-Netzwerke aus
#  2) Erzeugt/aktualisiert eine JSON-Konfiguration in /etc/tailscale-up-config.json
#  3) Erzeugt/aktualisiert einen systemd-Service /etc/systemd/system/tailscale-up.service
#  4) Aktiviert und startet diesen Service, sodass Tailscale die ausgewählten Routen bewirbt
#  5) Überprüft, ob tailscaled läuft
#  6) Bietet eine Option zur Deinstallation (Uninstaller) des Dienstes und der Konfigurationsdatei

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
CONFIG_FILE="/etc/tailscale-up-config.json"
SERVICE_FILE="/etc/systemd/system/tailscale-up.service"
SERVICE_NAME="tailscale-up.service"

# Das Service-Template wurde erweitert:
# - ExecStartPre wartet in einer Schleife (max. 12 Versuche à 5 Sekunden) darauf,
#   dass tailscaled den "Running"-Status meldet.
# - RemainAfterExit und Restart sorgen dafür, dass der Dienst im Fehlerfall neu gestartet wird.
SERVICE_TEMPLATE="[Unit]
Description=Tailscale Up - Advertise Docker Subnet(s)
After=tailscaled.service
Requires=tailscaled.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/bash -c \"n=0; while ! tailscale status --json 2>/dev/null | jq -e '.BackendState==\\\"Running\\\"' >/dev/null; do if [ \$n -ge 12 ]; then echo 'Tailscale hat nach 60 Sekunden keinen Running-Status erreicht.'; exit 1; fi; echo 'Warte auf Tailscale-Verbindung...'; n=\$((n+1)); sleep 5; done\"
ExecStart=/usr/bin/tailscale up --advertise-routes=ROUTES_PLACEHOLDER
RemainAfterExit=yes
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
"

# ---------------------------------------------------------------------------
# HILFSFUNKTIONEN
# ---------------------------------------------------------------------------
error() {
  echo "ERROR: $*" >&2
}

info() {
  echo "INFO: $*"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Dieses Skript muss als root ausgeführt werden!"
    exit 1
  fi
}

check_dependencies() {
  local deps=("docker" "tailscale" "jq" "systemctl")
  for bin in "${deps[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
      error "'$bin' ist nicht installiert oder nicht im PATH."
      exit 1
    fi
  done
}

# Prüft, ob tailscaled.service läuft und versucht ggf. zu starten
ensure_tailscaled_running() {
  info "Prüfe, ob tailscaled.service läuft..."
  if ! systemctl is-active --quiet tailscaled.service; then
    info "tailscaled.service ist nicht aktiv. Versuche zu starten..."
    systemctl start tailscaled.service
    sleep 2
  fi

  if ! systemctl is-active --quiet tailscaled.service; then
    error "tailscaled.service konnte nicht gestartet werden oder ist nicht aktiv."
    exit 1
  fi
  info "tailscaled.service ist aktiv."
}

# Wartet darauf, dass Tailscale den Status "Running" (über JSON) meldet
wait_for_tailscale() {
  info "Warte darauf, dass Tailscale aktiv wird (Status Connected)..."
  local retries=0
  local max_retries=12  # 12 * 5 Sekunden = 60 Sekunden
  while true; do
    if tailscale status --json 2>/dev/null | jq -e '.BackendState=="Running"' >/dev/null; then
      info "Tailscale ist aktiv und läuft."
      break
    else
      ((retries++))
      if ((retries>=max_retries)); then
        error "Tailscale wurde nicht innerhalb von 60 Sekunden aktiv."
        exit 1
      fi
      info "Tailscale ist noch nicht aktiv, warte 5 Sekunden..."
      sleep 5
    fi
  done
}

# Liest Docker-Netzwerke aus und gibt eine Liste an Einträgen im Format "Netzwerkname;Subnet" aus
get_docker_subnets() {
  local networks
  networks="$(docker network ls --format '{{.Name}}')"
  if [[ -z "$networks" ]]; then
    error "Keine Docker-Netzwerke gefunden oder Docker läuft nicht."
    return 1
  fi

  while IFS= read -r net; do
    local inspect
    inspect="$(docker network inspect "$net" 2>/dev/null)"
    if [[ -n "$inspect" ]]; then
      local subnets
      subnets="$(echo "$inspect" | jq -r '.[0].IPAM.Config[]?.Subnet? // empty')"
      if [[ -n "$subnets" ]]; then
        while IFS= read -r sb; do
          echo "$net;$sb"
        done <<< "$subnets"
      fi
    fi
  done <<< "$networks"
}

# Lädt Routen aus der JSON-Konfigurationsdatei
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[]" 
    return 0
  fi
  local output
  output="$(jq -r '.routes // []' "$CONFIG_FILE" 2>/dev/null || echo "[]")"
  echo "$output"
}

# Speichert eine Liste von Routen (als JSON-Array) in der Konfigurationsdatei
save_config() {
  local json_routes="$1"
  local new_config
  if [[ -f "$CONFIG_FILE" ]]; then
    new_config="$(jq --argjson routes "$json_routes" '.routes = $routes' "$CONFIG_FILE" 2>/dev/null || echo '{}')"
  else
    new_config="$(jq -n --argjson routes "$json_routes" '{ "routes": $routes }')"
  fi

  echo "$new_config" > "$CONFIG_FILE"
  info "Konfiguration gespeichert in $CONFIG_FILE"
}

# Erzeugt die systemd-Service-Datei mit den angegebenen Routen
create_service_file() {
  local routes_array=("$@")
  local routes_csv
  routes_csv="$(IFS=,; echo "${routes_array[*]}")"
  local content="${SERVICE_TEMPLATE//ROUTES_PLACEHOLDER/$routes_csv}"

  echo "$content" > "$SERVICE_FILE"
  info "Service-Datei $SERVICE_FILE erstellt (bzw. überschrieben)."
}

reload_and_restart_service() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  if ! systemctl restart "$SERVICE_NAME"; then
    error "Fehler beim Neustarten von $SERVICE_NAME"
    exit 1
  fi
  info "$SERVICE_NAME aktiviert und gestartet."
}

# Funktion zur Deinstallation: Stoppt und deaktiviert den Service sowie löscht die Service- und Konfigurationsdatei
uninstall_service() {
  info "Deinstallation wird durchgeführt..."
  systemctl stop "$SERVICE_NAME" && info "Service gestoppt." || info "Service war nicht aktiv."
  systemctl disable "$SERVICE_NAME" && info "Service deaktiviert." || info "Service konnte nicht deaktiviert werden."
  rm -f "$SERVICE_FILE" && info "Service-Datei $SERVICE_FILE entfernt." || error "Service-Datei konnte nicht entfernt werden."
  rm -f "$CONFIG_FILE" && info "Konfigurationsdatei $CONFIG_FILE entfernt." || error "Konfigurationsdatei konnte nicht entfernt werden."
  systemctl daemon-reload
  info "tailscale-up wurde deinstalliert."
  exit 0
}

# Interaktive Erstkonfiguration: Auswahl der zu bewerbenden Docker-Subnetze
initial_setup() {
  local netarray
  mapfile -t netarray < <(get_docker_subnets)
  if [[ ${#netarray[@]} -eq 0 ]]; then
    error "Keine verfügbaren Docker-Subnetze gefunden."
    exit 1
  fi

  echo "Verfügbare Docker-Netzwerke (Subnetze):"
  local -A index_map
  local index=1
  for entry in "${netarray[@]}"; do
    local name="${entry%%;*}"
    local sb="${entry#*;}"
    echo "  $index: $name - $sb"
    index_map["$index"]="$sb"
    ((index++))
  done

  echo -n "Gib die Nummern der Netzwerke ein, die du bewerben möchtest (z.B. 1,3,5): "
  read -r selection
  local chosen=()
  IFS=',' read -ra selarr <<< "$selection"
  for s in "${selarr[@]}"; do
    s="${s//[[:space:]]/}"
    if [[ -n "${index_map[$s]}" ]]; then
      chosen+=("${index_map[$s]}")
    fi
  done

  if [[ ${#chosen[@]} -eq 0 ]]; then
    error "Keine gültige Auswahl getroffen."
    exit 1
  fi

  local arr_json
  arr_json="$(printf '%s\n' "${chosen[@]}" | jq -R . | jq -s .)"
  save_config "$arr_json"
  create_service_file "${chosen[@]}"
  reload_and_restart_service
  wait_for_tailscale
}

# Menü zur Verwaltung einer bestehenden Installation
manage_existing() {
  local routes_json
  routes_json="$(load_config)"
  local current_routes=()
  mapfile -t current_routes < <(echo "$routes_json" | jq -r '.[]')

  if [[ ${#current_routes[@]} -eq 0 ]]; then
    info "Aktuell sind keine Routen beworben."
  else
    echo "Aktuell beworbene Routen:"
    local i=1
    for r in "${current_routes[@]}"; do
      echo "  $i) $r"
      ((i++))
    done
  fi

  local netarray
  mapfile -t netarray < <(get_docker_subnets)
  if [[ ${#netarray[@]} -eq 0 ]]; then
    error "Keine verfügbaren Docker-Subnetze."
  fi

  declare -A available_subnets
  for entry in "${netarray[@]}"; do
    local sb="${entry#*;}"
    available_subnets["$sb"]=1
  done

  echo ""
  echo "Optionen:"
  echo "  1) Netzwerk hinzufügen"
  echo "  2) Netzwerk entfernen"
  echo "  3) Ungültige (nicht mehr verfügbare) Routen entfernen"
  echo "  4) Beenden"
  echo "  5) Uninstall (Service und Konfiguration entfernen)"
  echo -n "Wähle eine Option: "
  read -r opt

  case "$opt" in
    "1")
      local -A index_map
      local idx=1
      echo "Verfügbare Docker-Netzwerke (nicht bereits beworben):"
      for entry in "${netarray[@]}"; do
        local sb="${entry#*;}"
        if [[ ! " ${current_routes[*]} " =~ " $sb " ]]; then
          local net="${entry%%;*}"
          echo "  $idx: $net - $sb"
          index_map["$idx"]="$sb"
          ((idx++))
        fi
      done

      if [[ $idx -eq 1 ]]; then
        echo "Es sind keine neuen Subnetze verfügbar."
        return
      fi

      echo -n "Gib die Nummern der Subnetze ein, getrennt durch Kommas: "
      read -r selection
      IFS=',' read -ra selarr <<< "$selection"
      for s in "${selarr[@]}"; do
        s="${s//[[:space:]]/}"
        if [[ -n "${index_map[$s]}" ]]; then
          current_routes+=("${index_map[$s]}")
        fi
      done
      ;;
    "2")
      if [[ ${#current_routes[@]} -eq 0 ]]; then
        echo "Keine Routen vorhanden, die entfernt werden könnten."
        return
      fi

      declare -A rm_index_map
      local i=1
      echo "Aktuell beworbene Routen:"
      for sb in "${current_routes[@]}"; do
        echo "  $i) $sb"
        rm_index_map["$i"]="$sb"
        ((i++))
      done
      echo -n "Gib die Nummern ein, die entfernt werden sollen (z. B. 1,2): "
      read -r selection
      IFS=',' read -ra selarr <<< "$selection"

      local new_routes=()
      for route in "${current_routes[@]}"; do
        local remove_flag=0
        for s in "${selarr[@]}"; do
          s="${s//[[:space:]]/}"
          if [[ "$route" == "${rm_index_map[$s]}" ]]; then
            remove_flag=1
            break
          fi
        done
        if [[ $remove_flag -eq 0 ]]; then
          new_routes+=("$route")
        fi
      done
      current_routes=("${new_routes[@]}")
      ;;
    "3")
      local new_routes=()
      for sb in "${current_routes[@]}"; do
        if [[ -n "${available_subnets[$sb]}" ]]; then
          new_routes+=("$sb")
        else
          echo "Entferne ungültige Route: $sb"
        fi
      done
      current_routes=("${new_routes[@]}")
      ;;
    "4")
      exit 0
      ;;
    "5")
      uninstall_service
      ;;
    *)
      echo "Ungültige Auswahl."
      exit 1
      ;;
  esac

  local arr_json
  arr_json="$(printf '%s\n' "${current_routes[@]}" | jq -R . | jq -s .)"
  save_config "$arr_json"
  create_service_file "${current_routes[@]}"
  reload_and_restart_service
  wait_for_tailscale
}

main() {
  check_root
  check_dependencies
  ensure_tailscaled_running

  if [[ ! -f "$SERVICE_FILE" || ! -f "$CONFIG_FILE" ]]; then
    info "Erstkonfiguration wird durchgeführt."
    initial_setup
  else
    info "tailscale-up.service und Konfiguration sind bereits vorhanden."
    manage_existing
  fi
}

main "$@"

