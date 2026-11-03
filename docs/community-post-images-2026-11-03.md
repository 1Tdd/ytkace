# Immagini dei post community

Nel menu aperto con una pressione prolungata su un post con più immagini, **Salva tutte le immagini** è ora una voce direttamente visibile. Il sottomenu Immagini conserva le azioni per le singole foto. Il comando per la foto corrente continua a usare quella premuta.

La raccolta cerca anche nei dati degli allegati e negli elementi del carosello, non solo nelle viste delle immagini già materializzate. I selettori ELM sono stati confrontati con l'indice delle classi dell'IPA fornito. Il testo del modello viene letto soltanto nel sottoalbero dell'allegato/carousel corrente, con limiti di nodi e dimensione; non viene scandito l'intero feed. Le varianti della stessa immagine a risoluzioni diverse vengono deduplicate, mantenendo l'ordine dei metadati e un URL di fallback.

Le immagini vengono richieste in risoluzione originale quando l'host lo supporta e salvate una alla volta in Foto: il batch non accumula tutte le immagini in memoria. Sono mostrati avanzamento, conteggio finale ed eventuali download mancanti. Se Foto rifiuta il salvataggio, il batch si interrompe riportando quante immagini erano già state salvate.

Il test nativo usa il parser di produzione e verifica immagini multiple/offscreen nei dati, ordine, duplicati, immagine premuta, URL originali, escape, host non validi e input malformato. L'integrazione con il carosello vivo di YouTube richiede ancora una prova sul dispositivo.

## Correzione dopo la prova sul dispositivo

La voce non dipende più dal rilevamento iniziale di due URL: compare in entrambi i menu quando Salva immagini dei post è attivo, con il conteggio delle immagini rilevate. Anche il pulsante nella foto ingrandita passa il nodo immagine e cerca il post di origine tra le celle già caricate, abbinando l'URL canonico della foto corrente. Le celle di altri post non vengono aggregate.

La raccolta attraversa inoltre i controller ELM e le celle lazy presenti nel controller di sezione, assenti dalle sole `subnodes`. Tutti i getter sono controllati per firma e gli ivar per tipo oggetto. La ricerca rimane limitata; non forza lo scorrimento o la creazione di altre celle.

Se il modello non fornisce URL, il comando resta visibile e riporta Nessuna immagine trovata. Il numero mostrato evita di presentare un numero sconosciuto di immagini come già rilevato. La verifica finale della UI e della completezza del carosello rimane sul dispositivo.
