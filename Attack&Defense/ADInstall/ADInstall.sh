#!/bin/bash
# Per usarlo:
# chmod +x setup.sh
# ./setup.sh config.cfg

# Verifica che sia stato passato il file di configurazione
if [ "$#" -ne 1 ]; then
    echo "Uso: $0 <file_di_configurazione.cfg>"
    exit 1
fi

CONFIG_FILE="$1"

# Verifica che il file esista
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Errore: File di configurazione '$CONFIG_FILE' non trovato."
    exit 1
fi

# Carica le variabili dal file di configurazione
source "$CONFIG_FILE"

# =========================================================

function configura_servizi_tulip {
    local config_file="$1"
    
    echo -e "\n=== Configurazione Servizi Tulip ==="

    # Costruisci la lista dei servizi in formato Python parsando la variabile SERVIZI
    local servizi_json="["
    local count=0
    
    for srv in $SERVIZI; do
        NOME_SERVIZIO=$(echo "$srv" | cut -d':' -f1)
        PORTA_SERVIZIO=$(echo "$srv" | cut -d':' -f2)
        
        if [ $count -gt 0 ]; then
            servizi_json+=", "
        fi
        
        echo "  Aggiunto: $NOME_SERVIZIO sulla porta $PORTA_SERVIZIO"
        servizi_json+="{\"ip\": \"$VM_IP\", \"port\": $PORTA_SERVIZIO, \"name\": \"$NOME_SERVIZIO\"}"
        count=$((count+1))
    done

    servizi_json+="]"

    # Backup del file originale
    cp "$config_file" "$config_file.backup"

    # Modifica le variabili nel file di configurazione Python
    sed -i "s|^vm_ip = .*|vm_ip = \"$VM_IP\"|" "$config_file"

    # Elimina tutte le righe da 'services =' fino alla fine del blocco
    sed -i "s|^services = .*|services = $servizi_json|" "$config_file"

    echo "Configurazione Tulip completata in $config_file"
}

function configura_s4dfarm {
    local s4d_dir="$1"
    echo -e "\n=== Configurazione S4DFarm ==="
    
    local config_file="$s4d_dir/server/app/config.py"
    cp "$config_file" "$config_file.backup"
    
    # Modifica le variabili nel file di configurazione
    sed -i "s|SCOREBOARD_IP = .*|SCOREBOARD_IP = \"$SCOREBOARD_IP\"|" "$config_file"
    sed -i "s|FLAG_SUBMIT_URL = .*|FLAG_SUBMIT_URL = \"$FLAG_SUBMIT_URL\"|" "$config_file"
    sed -i "s|S4D_PASSWORD = .*|S4D_PASSWORD = \"$S4D_PASSWORD\"|" "$config_file"
    sed -i "s|TEAM_TOKEN = .*|TEAM_TOKEN = \"$TEAM_TOKEN\"|" "$config_file"
    sed -i "s|NUMBER_OF_TEAMS = .*|NUMBER_OF_TEAMS = $NUMBER_OF_TEAMS|" "$config_file"
    
    echo "Configurazione S4DFarm completata in $config_file"
    
    # Verifica Docker Compose
    local compose_file="$s4d_dir/docker-compose.yml"
    if [ -f "$compose_file" ]; then
        echo "File docker-compose.yml trovato."
    else
        echo "Attenzione: file docker-compose.yml non trovato in $s4d_dir"
    fi
}

# Main script
echo "=== Script di configurazione per CTF Attack/Defense (Modalità Automatica) ==="

# Memorizza la directory corrente
SCRIPT_DIR=$(pwd)
echo "Directory di lavoro: $SCRIPT_DIR"

# Pulizia cartelle esistenti
echo -e "\n[1/7] Pulizia cartelle esistenti..."
[ -d "tulip-auth" ] && echo "  Eliminazione tulip-auth..." && rm -rf tulip-auth
[ -d "S4DFarm" ] && echo "  Eliminazione S4DFarm..." && rm -rf S4DFarm

# Installa i pacchetti necessari e configura tcpdump
echo -e "\n[2/7] Installazione pacchetti e configurazione tcpdump..."
sudo apt update && sudo apt install -y apparmor-utils apache2-utils && sudo aa-complain tcpdump

# Crea la directory per il traffico e imposta i permessi
echo -e "\n[3/7] Configurazione cattura traffico..."
sudo mkdir -p /traffic && sudo chown tcpdump:tcpdump /traffic
cd /traffic
sudo tcpdump -i game -G 60 -C 100 -w dump-%m-%d-%H-%M-%S-%s.pcap 'port not 22' &
TCPDUMP_PID=$!
disown $TCPDUMP_PID
echo "  Cattura traffico avviata (PID: $TCPDUMP_PID)"
cd "$SCRIPT_DIR"

# Clona i repository
echo -e "\n[4/7] Clonazione repository..."
git clone https://github.com/gcammisa/tulip-auth.git
git clone https://github.com/gcammisa/S4DFarm.git

# Configurazione Firegex
echo -e "\n[5/7] Configurazione Firegex..."
bash <(curl -sLf https://pwnzer0tt1.it/firegex.sh)

# Configurazione Tulip
echo -e "\n[7/7] Configurazione Tulip-auth..."
cd "$SCRIPT_DIR/tulip-auth"

# Configura i servizi di Tulip (passa solo il file, la VM_IP è globale)
configura_servizi_tulip "services/configurations.py"

# Configura il file .env
echo -e "\nConfigurazione file .env..."
cp .env.example .env
sed -i "s|TRAFFIC_DIR_HOST=.*|TRAFFIC_DIR_HOST=\"/traffic\"|" .env
sed -i "s|TICK_LENGTH=.*|TICK_LENGTH=120000|" .env

# Crea utente per l'autenticazione (usando modalità batch -b per evitare prompt)
echo -e "\nCreazione credenziali web per l'utente '$USERNAME'..."
[ -f ".htpasswd" ] && rm -f .htpasswd
# Usa -b per passare la password via riga di comando senza interruzioni
htpasswd -cb .htpasswd "$USERNAME" "$USER_PASSWORD"

if [ -f ".htpasswd" ]; then
    echo "File .htpasswd creato con successo"
else
    echo "ERRORE: Impossibile creare il file .htpasswd"
fi

# Configurazione S4DFarm
cd "$SCRIPT_DIR/S4DFarm"
configura_s4dfarm "$(pwd)"

# Avvio i container Docker
echo -e "\n[9/9] Avvio container Docker..."
echo -e "\nAvvio Tulip..."
cd "$SCRIPT_DIR/tulip-auth"
sudo docker compose up --build -d

echo -e "\nAvvio S4DFarm..."
cd "$SCRIPT_DIR/S4DFarm"
sudo docker compose up --build -d


echo -e "\n======================================================="
echo -e "=== Configurazione completata con successo! ==="
echo -e "======================================================="
echo "Tulip       : http://$VM_IP:3001"
echo "S4DFarm     : http://$VM_IP:5137"
echo "FiRegex   : https://$VM_IP:4444"
echo "Utente web  : $USERNAME"
echo "======================================================="
