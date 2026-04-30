# Come scrivere un exploit per competizioni di Attack & Defence
Scriptare un *exploit* durante una competizione AD, risulta pressochè fondamentale. Questo tutorial (consideratelo più una checklist) serve ad evidenziare tutti i requisiti necessari affinchè lo script possa funzionare correttamente, supponendo di utilizzare come servizio per l'invio delle flag **S4dFarm**.
### Shebang
La riga **shebang** (#!) è la primissima riga negli script Unix/Linux che specifica l'interprete. lo script ```start_sploit.py``` permette di scrivere l'exploit con il linguaggio di programmazione che si preferisce. per *python* lo shebang da utilizzare è:

```#!/usr/bin/env pyhton3```

### Ip come argomento in ingresso
```start_sploit.py``` esegue periodicamente l’exploit su ciascuna *VulnBox* presente nella rete di gioco. Per specificare quale macchina attaccare è necessario fornire l’indirizzo IP; di conseguenza, lo script di attacco deve essere in grado di accettare argomenti da riga di comando. Per rendere possibile questa cosa possiamo usare ```sys.argv[1]```.
### Includere il *flush*
Quando stampiamo qualcosa, il sistema operativo (e il runtime) utilizza un meccanismo intermedio chiamato **buffering dell’output**, per motivi di ottimizzazione: i dati non vengono scritti immediatamente, ma accumulati in un buffer fino a quando questo non si riempie o il programma termina. Il flush permette di svuotare immediatamente tutto il buffer senza aspettare. Senza il nostro caro e amato *flush*, quindi, esiste la possibilità che una flag rimanga all’interno del *buffer* e non venga mai effettivamente inviata. Per risolvere questo problema, È sufficiente passare l’argomento ```flush=True``` alla funzione di stampa che contiene la flag.

```print(output_con_la_flag, flush=True)```

## Esempio di exploit
Qui sotto c’è un esempio di exploit che mette insieme tutto quello visto finora:

```
#!/usr/bin/env python3 # Shebang
import requests
import sys

ip = sys.argv[1] # Ip come argomento

host = "http://"+ ip +":3000"

def exploit():
    # Tutto l'exploit
    print(flag, flush=True) # Utilizzo del flush

if __name__ == "__main__":
```

## Avvio dell'exploit
È il momento di lanciare l'exploit e papparsi tutti i punti dei nostri avversari. Ci faremo aiutare da ```start_sploit.py``` (precentemente citato):

```python3 start_sploit.py --server-url {URL:5137} --server-pass {PASSWORD} exploit.py```
