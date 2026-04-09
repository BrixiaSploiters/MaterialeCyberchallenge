# ADInstall refactor

Script di installazione e configurazione per l'ambiente Attack&Defense

## File

- `ADInstall.sh`
- `adinstall.conf.example`: esempio completo di configurazione.

## Uso

```bash
cp adinstall.conf.example adinstall.conf
vim adinstall.conf
chmod +x ADInstall.sh
sudo ./ADInstall.refactored.sh ./adinstall.conf
```

## Struttura del `.conf`

- `[global]`: directory di lavoro e avvio finale dei servizi.
- `[cleanup]`: pulizia iniziale, backup config e rimozione artefatti.
- `[packages]`: pacchetti APT da installare.
- `[traffic]`: directory dump pacchetti, interfaccia, rotazione e filtro tcpdump.
- `[git]`: URL dei repository e politica di update.
- `[firegex]`: installazione Firegex.
- `[portainer]`: immagine, nome container, volume e porte.
- `[tulip]`: percorsi Tulip e comando compose.
- `[tulip.python]`: override diretti al file Python di configurazione.
- `[tulip.env]`: override del file `.env`.
- `[tulip.auth]`: credenziali `.htpasswd`.
- `[s4dfarm]`: percorsi S4DFarm e comando compose.
- `[s4dfarm.python]`: override diretti al file Python di configurazione.

## Note pratiche

- Per rendere l'installazione piu' pulita possibile, abilita `[cleanup].enabled=true` e regola le altre opzioni.
- I valori nelle sezioni `*.python` devono essere scritti come letterali Python validi.
- I valori nelle sezioni `*.env` vengono scritti come `CHIAVE=valore`.
