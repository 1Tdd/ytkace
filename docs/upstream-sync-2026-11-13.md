# Allineamento upstream del 13 novembre 2026

Integrato `itzzace/ytkace` fino a `c85f15b` (Add fullscreen bar button toggles), 72 commit dopo `bea1a28`, mantenendo le modifiche del fork. Versione del fork: 1.2.1.

- Base IPA iOS 17+: YouTube 21.45.4 (prima 21.44.4); iOS 16: 21.33.6. Aggiornato anche il fallback URL del workflow IPA. Il workflow Hooks controlla ancora la baseline 21.44.4.
- Nuovo da upstream: Return YouTube Dislike, editor della disposizione dei pulsanti del player, pulsante qualità, schermo intero automatico e uscita a fine video, salto Precedente/Successivo, scheda playlist, Continua a riprodurre, supporto iPhone Duo, blocco heartbeat, correzioni HLS e prodotti.
- SponsorBlock: resta quello del fork. Preso da upstream solo Lunghezza minima segmento. Non aggiunti SponsorMenu né la seconda whitelist upstream, perché il fork ne ha già una. Nell'editor dei pulsanti la voce SponsorBlock comanda il pulsante del fork.
- Annunci: adottato il nuovo `AdsHooks.mm` upstream (filtro sui byte, meno hook sul feed). Riportati il filtro del fork per le live negli Short (`setReels:`) e la regola che evitava lo Short nero.
- Velocità: usata la pressione prolungata upstream per aprire il menu velocità; i pulsanti restano nella colonna a sinistra del fork, quindi l'editor non li sposta.
- Shorts: scorrimento automatico con le protezioni del fork contro i doppi salti, più l'attesa con i commenti aperti e il ritardo configurabile di upstream.
- Download: resta la schermata opzioni del fork; Qualità video predefinita ora preseleziona la qualità nella schermata, Lingua audio predefinita vale nei menu audio. Preso il fix upstream per il pulsante download con HLS.
- PiP: resta l'avvio nativo del fork, già provato su iPhone.
- Coda: presa la sincronizzazione riscritta upstream, che copre anche la coda svuotata.
- Prodotti: presa la logica upstream che nasconde solo gli scaffali con prodotti.

Nulla di questo è provato su iPhone al momento del merge.
