# Download e finalizzazione: audit del 3 novembre 2026

## Problemi individuati

- Unione, sottotitoli, conversione e capitoli usavano `faststart`: una seconda passata per spostare l'indice MP4, con lettura/scrittura aggiuntiva del file. Il vantaggio riguarda lo streaming progressivo, non la riproduzione di file locali. Riferimento: https://ffmpeg.org/ffmpeg-formats.html#mov_002c-mp4_002c-ismv
- La personalizzazione dei sottotitoli leggeva tutto il video in RAM, cercava la stringa `tx3g` anche nei dati audio/video e riscriveva il file intero. Ora attraversa le strutture MP4, salta il contenuto multimediale e modifica soltanto 30 byte per traccia.
- La miniatura provocava un'altra esportazione del video completo. Per i video viene mantenuta come JPG separato, già supportato dalla libreria; l'audio mantiene la copertina incorporata. La miniatura separata non viene incorporata nel video esportato.
- Ogni riga del log riscriveva fino a 512 KiB: migliaia di messaggi durante SABR potevano generare molto I/O aggiuntivo. Ora il log viene accodato, con rotazione solo al limite e senza spezzare caratteri UTF-8.
- I blocchi Direct non avevano un autorelease pool per iterazione; ora la memoria temporanea viene liberata dopo ogni blocco. SABR non duplica più la risposta completa prima di analizzarla.
- “Unisci” rimaneva al 96% durante più operazioni. Unione, sottotitoli e capitoli ora hanno percentuali proprie, annullamento e tempi nei log.

## Correzioni di affidabilità

- Direct verifica Content-Range, offset, lunghezza totale e dimensione del corpo; interrompe risposte che ignorano Range e inviano un file grande intero. Un rinnovo dell'URL non può concatenare formati, lingue o dimensioni incompatibili.
- Il limite di attesa del blocco riguarda l'inattività; annullamento e timeout non recuperano risultati ancora modificati dal callback.
- Errori di scrittura, lettura e chiusura dei file vengono propagati, inclusi quelli durante l'aggiunta dei sottotitoli. Non si consegna un file parziale come se fosse completo.
- I sottotitoli vengono scritti in ordine temporale insieme ai pacchetti multimediali. Ripetizioni dello stesso testo separate da un intervallo non rimangono visibili durante quell'intervallo.
- Sostituzione dei sottotitoli e ripristino dei file del backup senza cancellare prima l'originale; gli errori del ripristino vengono restituiti al chiamante.
- Chiusura corretta dei job cancellati e del task iOS in background.
- Conservate e verificate le modifiche locali preesistenti: scrittura Direct/SABR con errori espliciti, avvio SABR non duplicato, risposta fresca prioritaria sulla cache, fallback dei formati, playlist senza finestre sottotitoli per ogni elemento, nomi file limitati in byte UTF-8.
- Integrati gli aggiornamenti già presenti su origin/main fino a 274345b, inclusi conservazione e condivisione dei capitoli. Nessuna integrazione della versione upstream di SponsorBlock.

## Verifica e limiti

Test locali Python riusciti. Su Windows mancano compilatore C++ e librerie FFmpeg: i gruppi nativi vengono saltati localmente e devono passare nella build GitHub.

Nuovi test compilano la funzione di produzione per i sottotitoli: strutture normali/estese, più tracce, dati multimediali contenenti falsi tx3g, file malformati senza modifiche parziali, offset oltre 4 GiB con file sparso, MP4 FFmpeg reale ancora decodificabile e sottotitoli leggibili.

La copia dei pacchetti resta necessaria per unire audio/video e per aggiungere sottotitoli/capitoli. Non ricodifica il video e non beneficia della GPU. L'eventuale conversione AV1/VP9 è una fase distinta e mantiene VideoToolbox dove disponibile.

Non è stata misurata la velocità sul dispositivo dell'utente o sullo stesso video da 1,5 GB. Nessuna promessa di moltiplicatori di velocità: rete/CDN, formato, spazio libero e memoria del telefono restano rilevanti. Gli MP4 locali ora hanno normalmente l'indice in fondo; per lo streaming progressivo su un server web può essere utile una successiva ottimizzazione faststart.
